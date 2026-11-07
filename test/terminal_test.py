"""Outer: interactive terminal attachment, explicit IDs and cancellation on owned PTYs."""
import fcntl
import os
from pathlib import Path
import pty
import selectors
import struct
import subprocess
import sys
import termios
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/terminal_peer.exe"


def wait_with_terminal(child, master):
    pidfd = os.pidfd_open(child.pid)
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(pidfd, selectors.EVENT_READ)
            ready.register(master, selectors.EVENT_READ)
            while True:
                events = ready.select(1)
                assert events, "terminal operation did not progress"
                if any(key.fd == pidfd for key, _ in events):
                    return child.wait(timeout=1)
                for key, _ in events:
                    if key.fd == master:
                        os.read(master, 65536)
    finally:
        os.close(pidfd)


for binary in sys.argv[1:]:
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture:
            session = "terminal * ; exact"
            session_id = fixture.command("new-session", "-d", "-P", "-F", "#{session_id}", "-s", session, "exec cat").stdout.decode().strip()
            fixture.track_panes()
            fixture.command("set-option", "-t", session_id, "update-environment", "TERMINAL_POLICY")
            fixture.command("set-hook", "-g", "client-attached", "wait-for -S terminal-ready")
            for mode in ["detach", "cancel", "update", "missing", "invalid", "pre_cancel"]:
                fixture.command("set-environment", "-t", session_id, "TERMINAL_POLICY", "old")
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                process = None
                ready = None
                attached_pidfd = None
                try:
                    target = "$999999" if mode == "missing" else session_id
                    process = subprocess.Popen(
                        [str(peer), fixture.binary, str(fixture.socket), backend, os.ttyname(slave), target, mode],
                        env=fixture.environment | {"TERM": "xterm", "TERMINAL_POLICY": "new",
                                                   "TMUX": "invalid-inherited", "TMUX_PANE": "%99999"},
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    if mode in {"detach", "cancel", "update"}:
                        ready = subprocess.Popen(
                            [fixture.binary, "-S", str(fixture.socket), "wait-for", "terminal-ready"],
                            env=fixture.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        )
                        assert wait_with_terminal(ready, master) == 0
                        clients = fixture.command("list-clients", "-F", "#{client_pid}\t#{client_name}\t#{client_readonly}").stdout.splitlines()
                        assert len(clients) == 1, clients
                        pid, name, readonly = clients[0].split(b"\t")
                        assert readonly == b"1"
                        attached_pidfd = os.pidfd_open(int(pid))
                        expected = b"new" if mode == "update" else b"old"
                        assert fixture.command("show-environment", "-t", session_id, "TERMINAL_POLICY").stdout == b"TERMINAL_POLICY=" + expected + b"\n"
                        if mode == "cancel":
                            process.stdin.write(b"CANCEL\n")
                            process.stdin.flush()
                        else:
                            fixture.command("detach-client", "-t", name.decode() + ":")
                    assert wait_with_terminal(process, master) == 0, process.stderr.read()
                    stdout, stderr = process.communicate(timeout=1)
                    assert stdout == b"PASS terminal attachment and reaping\n", (backend, mode, stdout, stderr)
                    assert stderr == b"", stderr
                    if attached_pidfd is not None:
                        with selectors.DefaultSelector() as exited:
                            exited.register(attached_pidfd, selectors.EVENT_READ)
                            assert exited.select(0), "attachment returned before child exit"
                    assert fixture.command("list-clients").stdout == b""
                    assert fixture.command("has-session", "-t", session_id).returncode == 0
                finally:
                    for child in [process, ready]:
                        if child is not None:
                            if child.poll() is None:
                                child.kill()
                                child.wait(timeout=1)
                            for stream in [child.stdin, child.stdout, child.stderr]:
                                if stream is not None:
                                    stream.close()
                    if attached_pidfd is not None:
                        os.close(attached_pidfd)
                    os.close(master)
                    os.close(slave)
            print(f"PASS {Path(binary).parent.name} {backend}: terminal IDs, policy, cancellation and exit")
