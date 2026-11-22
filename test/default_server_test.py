"""Outer: default server selection (LIBTMUX_SOCKET_PATH, LIBTMUX_SOCKET, TMUX, default)."""

import contextlib
import ctypes
import os
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

from support.tmux_fixture import AMBIENT_SELECTORS

root = Path(__file__).resolve().parents[1]
peer = root / "_build/default/test/default_server_peer.exe"
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")


def verify_sandbox(env: dict[str, str]) -> Path:
    sandbox = env.get("LIBTMUX_TEST_SANDBOX", "")
    tmpdir = env.get("TMUX_TMPDIR", "")
    if not sandbox or sandbox != tmpdir:
        raise RuntimeError(
            "named/default socket test requires matching LIBTMUX_TEST_SANDBOX"
        )
    path = Path(sandbox)
    if not path.is_dir() or (path.stat().st_mode & 0o077) != 0:
        raise RuntimeError("sandbox directory must exist with mode 0700")
    return path


class OwnedDaemon:
    """Start an isolated tmux daemon by -S path or -L name inside a verified sandbox."""

    def __init__(
        self,
        binary: str,
        base_env: dict[str, str],
        *,
        socket_path: Path | None = None,
        socket_name: str | None = None,
        session: str,
    ) -> None:
        self.binary = binary
        self.env = {k: v for k, v in base_env.items() if k not in AMBIENT_SELECTORS}
        self.session = session
        if socket_name is not None:
            sandbox = verify_sandbox(self.env).resolve(strict=True)
            user_dir = sandbox / f"tmux-{os.getuid()}"
            user_dir.mkdir(mode=0o700, exist_ok=True)
            self.watch_dir = user_dir
            self.socket = user_dir / socket_name
            self.selector = ["-L", socket_name]
        else:
            assert socket_path is not None
            socket_path.parent.mkdir(mode=0o700, exist_ok=True)
            self.watch_dir = socket_path.parent
            self.socket = socket_path
            self.selector = ["-S", str(socket_path)]
        self.server: subprocess.Popen[bytes] | None = None
        self.pidfd: int | None = None
        self.pane_pidfds: dict[int, int] = {}
        self.log = tempfile.TemporaryFile()  # noqa: SIM115  # closed in close()

    def command(
        self, *args: str, check: bool = True
    ) -> subprocess.CompletedProcess[bytes]:
        if "-L" in self.selector:
            verify_sandbox(self.env)
        return subprocess.run(
            [self.binary, *self.selector, *args],
            env=self.env,
            capture_output=True,
            check=check,
            timeout=1,
        )

    def start(self) -> "OwnedDaemon":
        notification = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if notification < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        try:
            watch = libc.inotify_add_watch(
                notification, os.fsencode(str(self.watch_dir)), 0x100 | 0x80
            )
            if watch < 0:
                raise OSError(ctypes.get_errno(), "inotify_add_watch")
            self.server = subprocess.Popen(
                [self.binary, "-D", *self.selector, "-f", "/dev/null"],
                env=self.env,
                stdin=subprocess.DEVNULL,
                stdout=self.log,
                stderr=self.log,
            )
            self.pidfd = os.pidfd_open(self.server.pid)
            with selectors.DefaultSelector() as ready:
                ready.register(notification, selectors.EVENT_READ)
                ready.register(self.pidfd, selectors.EVENT_READ)
                while not self.socket.exists():
                    events = ready.select(1)
                    if not events:
                        raise TimeoutError("owned daemon did not create socket")
                    if any(key.fd == self.pidfd for key, _ in events):
                        raise RuntimeError("owned daemon exited during startup")
                    os.read(notification, 4096)
            if not stat.S_ISSOCK(self.socket.stat().st_mode):
                raise RuntimeError("endpoint is not a socket")
            self.command("new-session", "-d", "-s", self.session, "exec cat")
            pid = int(self.command("display-message", "-p", "#{pid}").stdout)
            if pid != self.server.pid:
                raise RuntimeError("daemon reached an unowned server")
            self.track_panes()
            return self
        except BaseException:
            self.close()
            raise
        finally:
            os.close(notification)

    def track_panes(self) -> None:
        for line in self.command(
            "list-panes", "-a", "-F", "#{pane_pid}"
        ).stdout.splitlines():
            if line and int(line) > 0 and int(line) not in self.pane_pidfds:
                with contextlib.suppress(ProcessLookupError):
                    self.pane_pidfds[int(line)] = os.pidfd_open(int(line))

    def close(self) -> None:
        try:
            if self.server is not None and self.server.poll() is None:
                self.command("kill-server", check=False)
                self.server.wait(timeout=1)
            for fd in self.pane_pidfds.values():
                with selectors.DefaultSelector() as ready:
                    ready.register(fd, selectors.EVENT_READ)
                    if not ready.select(1):
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                        raise RuntimeError("owned pane did not exit")
        finally:
            if self.pidfd is not None:
                os.close(self.pidfd)
                self.pidfd = None
            for fd in self.pane_pidfds.values():
                os.close(fd)
            self.pane_pidfds.clear()
            self.log.close()


def stop_bootstrapped_socket(
    binary: str, socket: Path, env: dict[str, str], pid: int
) -> None:
    clean_env = {k: v for k, v in env.items() if k not in AMBIENT_SELECTORS}
    daemon_fd = os.pidfd_open(pid)
    pane_fds: list[int] = []
    try:
        rows = subprocess.run(
            [binary, "-N", "-S", str(socket), "list-panes", "-a", "-F", "#{pane_pid}"],
            env=clean_env,
            capture_output=True,
            check=True,
            timeout=1,
        ).stdout.splitlines()
        for row in rows:
            with contextlib.suppress(ProcessLookupError):
                pane_fds.append(os.pidfd_open(int(row)))
        signal.pidfd_send_signal(daemon_fd, signal.SIGTERM)
        with selectors.DefaultSelector() as ready:
            ready.register(daemon_fd, selectors.EVENT_READ)
            assert ready.select(1), "bootstrapped daemon did not exit"
        with contextlib.suppress(ChildProcessError):
            os.waitpid(pid, 0)
        for fd in pane_fds:
            with selectors.DefaultSelector() as ready:
                ready.register(fd, selectors.EVENT_READ)
                assert ready.select(1), "bootstrapped pane did not exit"
    finally:
        os.close(daemon_fd)
        for fd in pane_fds:
            os.close(fd)


def run_peer(*args: str, cwd: Path, env: dict[str, str]) -> tuple[int, str, str]:
    result = subprocess.run(
        [str(peer), *args],
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        timeout=2,
        check=True,
    )
    assert result.stderr == "", result.stderr
    pid_s, first, second = (
        result.stdout.strip().split("|", 2)
        if result.stdout.count("|") == 2
        else (*result.stdout.strip().split("|", 1), "")
    )
    return int(pid_s), first, second


def check(binary: str) -> None:
    actual = str(Path(binary).resolve(strict=True))
    release = Path(actual).parents[1].name
    with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-default-srv-") as raw_root:
        workdir = Path(raw_root)
        sandbox = workdir / "sandbox"
        sandbox.mkdir(mode=0o700)
        base_env = {k: v for k, v in os.environ.items() if k not in AMBIENT_SELECTORS}
        base_env["TMUX_TMPDIR"] = str(sandbox)
        base_env["LIBTMUX_TEST_SANDBOX"] = str(sandbox)
        verify_sandbox(base_env)

        daemons = [
            OwnedDaemon(actual, base_env, socket_name="default", session="s-default"),
            OwnedDaemon(actual, base_env, socket_name="named-srv", session="s-named"),
            OwnedDaemon(
                actual,
                base_env,
                socket_path=workdir / "enclosing.sock",
                session="s-enc",
            ),
            OwnedDaemon(
                actual,
                base_env,
                socket_path=workdir / "sub/path.sock",
                session="s-path",
            ),
        ]
        default_d, named_d, enclosing_d, path_d = daemons
        try:
            for daemon in daemons:
                daemon.start()
            assert (
                default_d.server
                and named_d.server
                and enclosing_d.server
                and path_d.server
            )

            for backend in ("unix", "eio"):
                # 1. Neither variable nor TMUX -> default socket in TMUX_TMPDIR
                pid, kind, val = run_peer(
                    "connect", actual, backend, cwd=workdir, env=base_env
                )
                assert (pid, kind, val) == (
                    default_d.server.pid,
                    "named_socket",
                    "default",
                )

                # 2. Empty/leading-comma TMUX -> default socket
                for ignored in ("", ",4242,0", "   ,4242,0"):
                    pid, kind, val = run_peer(
                        "connect",
                        actual,
                        backend,
                        cwd=workdir,
                        env=base_env | {"TMUX": ignored},
                    )
                    assert (pid, kind, val) == (
                        default_d.server.pid,
                        "named_socket",
                        "default",
                    )

                # 3. TMUX enclosing daemon (including extra comma fields and blank LIBTMUX_*)
                tmux_env = base_env | {
                    "LIBTMUX_SOCKET_PATH": "   ",
                    "LIBTMUX_SOCKET": "\t\n",
                    "TMUX": f"{enclosing_d.socket},extra,4242,0",
                    "TMUX_PANE": "%0",
                }
                pid, kind, val = run_peer(
                    "connect", actual, backend, cwd=workdir, env=tmux_env
                )
                assert (pid, kind, val) == (
                    enclosing_d.server.pid,
                    "socket_path",
                    str(enclosing_d.socket),
                )

                # 4. Nested create_session inside TMUX succeeds without nested refusal
                pid, session_id, _ = run_peer(
                    "nested",
                    actual,
                    backend,
                    f"nested-{backend}",
                    cwd=workdir,
                    env=tmux_env,
                )
                assert pid == enclosing_d.server.pid and session_id.startswith("$")
                enclosing_d.track_panes()

                # 5. LIBTMUX_SOCKET beats TMUX (including blank LIBTMUX_SOCKET_PATH)
                sock_env = tmux_env | {"LIBTMUX_SOCKET": "named-srv"}
                pid, kind, val = run_peer(
                    "connect", actual, backend, cwd=workdir, env=sock_env
                )
                assert (pid, kind, val) == (
                    named_d.server.pid,
                    "named_socket",
                    "named-srv",
                )

                # 6. Relative & absolute LIBTMUX_SOCKET_PATH beat LIBTMUX_SOCKET without error
                for raw_path in (str(path_d.socket), "sub/path.sock"):
                    path_env = sock_env | {
                        "LIBTMUX_SOCKET_PATH": raw_path,
                        "LIBTMUX_SOCKET": "invalid/slash",
                    }
                    pid, kind, val = run_peer(
                        "connect", actual, backend, cwd=workdir, env=path_env
                    )
                    assert (pid, kind, val) == (
                        path_d.server.pid,
                        "socket_path",
                        str(path_d.socket),
                    )

                # 7. Explicit endpoints ignore LIBTMUX_SOCKET_PATH, LIBTMUX_SOCKET, and TMUX
                hostile = base_env | {
                    "LIBTMUX_SOCKET_PATH": str(path_d.socket),
                    "LIBTMUX_SOCKET": "invalid/slash",
                    "TMUX": f"{enclosing_d.socket},4242,0",
                }
                pid, kind, val = run_peer(
                    "explicit",
                    actual,
                    backend,
                    "path",
                    str(enclosing_d.socket),
                    cwd=workdir,
                    env=hostile,
                )
                assert (pid, kind, val) == (
                    enclosing_d.server.pid,
                    "socket_path",
                    str(enclosing_d.socket),
                )
                pid, kind, val = run_peer(
                    "explicit",
                    actual,
                    backend,
                    "name",
                    "named-srv",
                    cwd=workdir,
                    env=hostile,
                )
                assert (pid, kind, val) == (
                    named_d.server.pid,
                    "named_socket",
                    "named-srv",
                )

                # 8. Bootstrap new-session on a fresh socket named in TMUX succeeds cleanly
                fresh_socket = workdir / f"fresh-tmux-{backend}.sock"
                fresh_env = base_env | {
                    "TMUX": f"{fresh_socket},9999,0",
                    "TMUX_PANE": "%9",
                }
                boot_pid, kind, val = run_peer(
                    "bootstrap",
                    actual,
                    backend,
                    f"boot-{backend}",
                    cwd=workdir,
                    env=fresh_env,
                )
                try:
                    assert (kind, val) == ("socket_path", str(fresh_socket))
                    assert fresh_socket.exists()
                finally:
                    stop_bootstrapped_socket(actual, fresh_socket, base_env, boot_pid)

                print(
                    f"PASS {release} {backend}: default server selection, TMUX routing and nested bootstrap"
                )
        finally:
            for daemon in reversed(daemons):
                daemon.close()


if __name__ == "__main__":
    for tmux_binary in sys.argv[1:]:
        check(tmux_binary)
