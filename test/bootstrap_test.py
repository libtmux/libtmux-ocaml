"""Outer: owned startup, same-connection binding and retained uncertain creation."""
import ctypes
import os
from pathlib import Path
import selectors
import shlex
import signal
import subprocess
import sys
import tempfile
from support.tmux_fixture import TmuxFixture

root = Path(__file__).resolve().parents[1]
peer = root / "_build/default/test/bootstrap_peer.exe"
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")


def exercise(binary, socket, environment, fresh):
    daemon = None
    pidfds = []
    process = subprocess.Popen([str(peer), binary, str(socket)], env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            assert ready.select(1), "bootstrap peer not ready"
        line = process.stdout.readline().split()
        assert len(line) == 3 and line[0] == b"READY", line
        daemon = int(line[1])
        pidfds.extend([os.pidfd_open(daemon), os.pidfd_open(int(line[2]))])
        result = subprocess.run([binary, "-S", str(socket), "list-panes", "-a", "-F", "#{pane_pid}"],
                                env=environment, capture_output=True, check=True, timeout=1)
        for pane in result.stdout.splitlines():
            pidfds.append(os.pidfd_open(int(pane)))
        process.stdin.write(b"continue\n")
        process.stdin.flush()
        stdout, stderr = process.communicate(timeout=1)
        assert process.returncode == 0, (stdout, stderr)
        assert stdout == b"PASS bound startup, collision, retained cancellation, healthy daemon\nCLOSED\n"
        assert not stderr, stderr
        # The cancelled startup deliberately leaves its proven creation in the journal.
        result = subprocess.run([binary, "-S", str(socket), "list-panes", "-a", "-F", "#{pane_pid}"],
                                env=environment, capture_output=True, check=True, timeout=1)
        for pane in result.stdout.splitlines():
            pidfds.append(os.pidfd_open(int(pane)))
        result = subprocess.run([binary, "-S", str(socket), "list-clients"],
                                env=environment, capture_output=True, check=True, timeout=1)
        assert result.stdout == b"", result
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        for stream in [process.stdin, process.stdout, process.stderr]:
            stream.close()
        if fresh and daemon is None and socket.exists():
            result = subprocess.run([binary, "-N", "-S", str(socket), "display-message", "-p", "#{pid}"],
                                    env=environment, capture_output=True, timeout=1, check=True)
            daemon = int(result.stdout)
            pidfds.append(os.pidfd_open(daemon))
        if fresh and daemon is not None:
            result = subprocess.run([binary, "-N", "-S", str(socket), "list-panes", "-a", "-F", "#{pane_pid}"],
                                    env=environment, capture_output=True, timeout=1, check=True)
            for pane in result.stdout.splitlines():
                pidfds.append(os.pidfd_open(int(pane)))
        if fresh and daemon is not None:
            signal.pidfd_send_signal(pidfds[0], signal.SIGTERM)
            with selectors.DefaultSelector() as ready:
                ready.register(pidfds[0], selectors.EVENT_READ)
                assert ready.select(1), "owned bootstrap daemon did not exit"
            os.waitpid(daemon, 0)
            for descriptor in pidfds[1:]:
                with selectors.DefaultSelector() as ready:
                    ready.register(descriptor, selectors.EVENT_READ)
                    assert ready.select(1), "owned bootstrap pane did not exit"
        for descriptor in pidfds:
            os.close(descriptor)


for binary in sys.argv[1:]:
    actual = str(Path(binary).resolve(strict=True))
    with TmuxFixture(actual) as fixture:
        try:
            exercise(actual, fixture.socket, fixture.environment, False)
        finally:
            fixture.track_panes()
    with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-bootstrap-") as directory:
        directory = Path(directory)
        wrapper = directory / "tmux"
        wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(actual)} -f /dev/null \"$@\"\n")
        wrapper.chmod(0o700)
        environment = {key:value for key,value in os.environ.items() if key not in {"TMUX", "TMUX_PANE"}}
        exercise(str(wrapper), directory / "server", environment, True)
    print(f"PASS {Path(binary).parent.name}: fresh/existing bootstrap, collision, cancelled startup receipt, teardown")
