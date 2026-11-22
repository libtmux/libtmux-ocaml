"""Owned Linux tmux fixtures. Readiness and teardown use kernel events."""

import contextlib
import ctypes
import os
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from collections.abc import Iterable, Mapping
from pathlib import Path

TEST_TMUX_ENV = "LIBTMUX_TEST_TMUX"
LEGACY_TEST_TMUX_ENV = "TMUX_BINARY"
AMBIENT_SELECTORS = frozenset(
    {"TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH"}
)


def configured_test_tmux(env: Mapping[str, str] | None = None) -> str | None:
    mapping = os.environ if env is None else env
    for key in (TEST_TMUX_ENV, LEGACY_TEST_TMUX_ENV):
        value = mapping.get(key)
        if value is not None and value.strip():
            return value
    return None


def resolve_test_tmux(
    binary: str | os.PathLike[str] | None = None,
    *,
    env: Mapping[str, str] | None = None,
) -> str:
    mapping = os.environ if env is None else env
    raw = os.fspath(binary) if binary is not None else configured_test_tmux(mapping)
    if raw is None:
        found = shutil.which("tmux", path=mapping.get("PATH"))
        if found is None:
            raise FileNotFoundError(
                f"tmux executable not found on PATH; set {TEST_TMUX_ENV}"
            )
        return str(Path(found).resolve(strict=True))
    if not raw.strip():
        raise FileNotFoundError("tmux executable path must not be empty")
    if os.sep in raw or (os.altsep is not None and os.altsep in raw):
        return str(Path(raw).resolve(strict=True))
    found = shutil.which(raw, path=mapping.get("PATH"))
    if found is None:
        raise FileNotFoundError(f"tmux executable {raw!r} not found on PATH")
    return str(Path(found).resolve(strict=True))


def test_tmux_binaries(
    argv: Iterable[str | os.PathLike[str]] | None = None,
    *,
    env: Mapping[str, str] | None = None,
) -> list[str]:
    arguments = sys.argv[1:] if argv is None else list(argv)
    if arguments:
        return [resolve_test_tmux(item, env=env) for item in arguments]
    return [resolve_test_tmux(env=env)]


class TmuxFixture:
    def __init__(self, binary=None):
        self.binary = resolve_test_tmux(binary)
        self.directory = tempfile.TemporaryDirectory(prefix="libtmux-ocaml-")
        self.socket = Path(self.directory.name) / "server"
        self.environment = {
            key: value
            for key, value in os.environ.items()
            if key not in AMBIENT_SELECTORS
        }
        self.server = None
        self.pidfd = None
        self.pane_pidfds = {}
        self.log = tempfile.TemporaryFile()  # noqa: SIM115  # closed in __exit__

    def command(self, *arguments, check=True):
        # A call to a running server answers in milliseconds; the bound only
        # catches a hung one.
        return subprocess.run(
            [self.binary, "-S", str(self.socket), *arguments],
            env=self.environment,
            capture_output=True,
            check=check,
            timeout=1,
        )

    def __enter__(self):
        libc = ctypes.CDLL(None, use_errno=True)
        notification = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
        if notification < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        try:
            watch = libc.inotify_add_watch(
                notification,
                os.fsencode(self.directory.name),
                0x100 | 0x80,
            )
            if watch < 0:
                raise OSError(ctypes.get_errno(), "inotify_add_watch")
            self.server = subprocess.Popen(
                [self.binary, "-D", "-S", str(self.socket), "-f", "/dev/null"],
                env=self.environment,
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
                        raise TimeoutError("owned tmux did not create its socket")
                    if any(key.fd == self.pidfd for key, _ in events):
                        raise RuntimeError("owned tmux exited during setup")
                    os.read(notification, 4096)
            if not stat.S_ISSOCK(self.socket.stat().st_mode):
                raise RuntimeError("tmux endpoint is not a socket")
            self.command("new-session", "-d", "-s", "fixture", "exec cat")
            pid = int(self.command("display-message", "-p", "#{pid}").stdout)
            if pid != self.server.pid:
                raise RuntimeError("fixture reached an unowned daemon")
            if not os.path.samefile(f"/proc/{pid}/ns/pid", "/proc/self/ns/pid"):
                raise RuntimeError("fixture requires a shared PID namespace")
            self.track_panes()
            return self
        except BaseException as error:
            self._close_preserving(error)
            raise
        finally:
            os.close(notification)

    def track_panes(self):
        for value in self.command(
            "list-panes", "-a", "-F", "#{pane_pid}"
        ).stdout.splitlines():
            if value and int(value) > 0 and int(value) not in self.pane_pidfds:
                with contextlib.suppress(ProcessLookupError):
                    self.pane_pidfds[int(value)] = os.pidfd_open(int(value))

    def close(self):
        try:
            if self.server is not None and self.server.poll() is None:
                try:
                    self.command("kill-server", check=False)
                    self.server.wait(timeout=1)
                except (subprocess.TimeoutExpired, OSError):
                    self.server.kill()
                    self.server.wait(timeout=1)
                    raise
            for pane_pidfd in self.pane_pidfds.values():
                with selectors.DefaultSelector() as ready:
                    ready.register(pane_pidfd, selectors.EVENT_READ)
                    if not ready.select(1):
                        signal.pidfd_send_signal(pane_pidfd, signal.SIGKILL)
                        raise RuntimeError("owned pane did not exit with its daemon")
        finally:
            if self.pidfd is not None:
                os.close(self.pidfd)
                self.pidfd = None
            for descriptor in self.pane_pidfds.values():
                os.close(descriptor)
            self.pane_pidfds.clear()
            self.log.close()
            self.directory.cleanup()

    def _close_preserving(self, primary):
        try:
            self.close()
        except BaseException as cleanup:
            if primary is None:
                raise
            primary.add_note(
                f"fixture cleanup failed: {cleanup!r}; "
                f"stdout={getattr(cleanup, 'stdout', None)!r}; "
                f"stderr={getattr(cleanup, 'stderr', None)!r}"
            )

    def __exit__(self, _kind, error, _traceback):
        self._close_preserving(error)
