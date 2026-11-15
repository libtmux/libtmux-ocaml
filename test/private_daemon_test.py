"""Outer: private daemons, kill-server and bootstrap config files on both backends."""

import os
import selectors
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
peer = root / "_build/default/test/private_daemon_peer.exe"
BOGUS = {"TMUX": "/unrelated/server,99999,0", "TMUX_PANE": "%99999"}


def exited(descriptor: int) -> bool:
    with selectors.DefaultSelector() as ready:
        ready.register(descriptor, selectors.EVENT_READ)
        return bool(ready.select(1))


def run(
    binary: str, backend: str, mode: str, *extra: str, workdir: Path
) -> subprocess.Popen[bytes]:
    environment = dict(os.environ, **BOGUS)
    return subprocess.Popen(
        [str(peer), binary, backend, mode, *extra],
        cwd=workdir,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def tmux(binary: str, socket: Path, *arguments: str) -> bytes:
    environment = {k: v for k, v in os.environ.items() if k not in BOGUS}
    return subprocess.run(
        [binary, "-N", "-S", str(socket), *arguments],
        env=environment,
        capture_output=True,
        check=True,
        timeout=1,
    ).stdout


def serve(binary: str, backend: str, mode: str, workdir: Path) -> None:
    """Run a mode that holds its daemon open, then check the teardown."""
    process = run(binary, backend, mode, workdir=workdir)
    stdin, stdout = process.stdin, process.stdout
    assert stdin is not None and stdout is not None
    descriptors = []
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(stdout, selectors.EVENT_READ)
            assert ready.select(1), "peer did not report a daemon"
        line = stdout.readline().split()
        assert len(line) == 3 and line[0] == b"READY", line
        pid, directory = int(line[1]), Path(os.fsdecode(line[2]))
        socket = directory / "server"
        assert directory.name.startswith("libtmux-ocaml-")
        assert directory.stat().st_mode & 0o077 == 0
        assert int(tmux(binary, socket, "display-message", "-p", "#{pid}")) == pid
        names = tmux(binary, socket, "list-sessions", "-F", "#{session_name}")
        assert sorted(names.split()) == [b"second", b"seed"], names
        environ = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        assert not [e for e in environ if e.startswith((b"TMUX=", b"TMUX_PANE="))]
        descriptors.append(os.pidfd_open(pid))
        for pane in tmux(
            binary, socket, "list-panes", "-a", "-F", "#{pane_pid}"
        ).split():
            descriptors.append(os.pidfd_open(int(pane)))
        stdin.write(b"continue\n")
        stdin.flush()
        out, err = process.communicate(timeout=2)
        assert process.returncode == 0 and not err, (process.returncode, out, err)
        assert out == (b"RAISED boom\n" if mode == "raise" else b"DONE\n"), out
        assert not directory.exists(), "private directory was left behind"
        assert all(exited(d) for d in descriptors), "daemon or pane outlived the scope"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        for stream in (stdin, stdout, process.stderr):
            if stream is not None:
                stream.close()
        for descriptor in descriptors:
            if not exited(descriptor):
                signal.pidfd_send_signal(descriptor, signal.SIGKILL)
            os.close(descriptor)


def once(
    binary: str, backend: str, mode: str, *extra: str, workdir: Path
) -> list[bytes]:
    """Run a mode that finishes without a handshake and return its output."""
    process = run(binary, backend, mode, *extra, workdir=workdir)
    out, err = process.communicate(timeout=3)
    assert process.returncode == 0 and not err, (backend, mode, out, err)
    return out.splitlines()


def check(binary: str) -> None:
    name = Path(binary).resolve().parents[1].name
    with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-private-test-") as work:
        workdir = Path(work)
        config = workdir / "tmux.conf"
        config.write_text("set-option -s escape-time 13\n")
        for backend in ("unix", "eio"):
            for mode in ("run", "raise"):
                serve(binary, backend, mode, workdir)
            killed = once(binary, backend, "kill", workdir=workdir)
            assert killed[0].startswith(b"KILLED ") and killed[1] == b"DONE", killed
            pid = int(killed[0].split()[1])
            assert not Path(f"/proc/{pid}").exists(), "killed daemon still runs"
            seeded = once(binary, backend, "session", workdir=workdir)
            assert seeded[0].startswith(b"SEEDED ") and seeded[1] == b"DONE", seeded
            pid = int(seeded[0].split()[1])
            assert not Path(f"/proc/{pid}").exists(), "seeded daemon still runs"
            configured = once(binary, backend, "config", str(config), workdir=workdir)
            assert configured[0].startswith(b"CONFIG ") and configured[1] == b"DONE"
            socket = workdir / f"bootstrap-{backend}"
            started = once(
                binary,
                backend,
                "bootstrap-config",
                str(config),
                str(socket),
                workdir=workdir,
            )
            assert started[0].startswith(b"CONFIG ") and started[1] == b"DONE", started
            pid = int(started[0].split()[1])
            assert not Path(f"/proc/{pid}").exists(), "bootstrapped daemon still runs"
            print(
                f"PASS {name} {backend}: private daemon, kill-server and bootstrap config file"
            )
        assert not list(workdir.glob("libtmux-ocaml-*"))


if __name__ == "__main__":
    for tmux_binary in sys.argv[1:]:
        check(str(Path(tmux_binary).resolve(strict=True)))
