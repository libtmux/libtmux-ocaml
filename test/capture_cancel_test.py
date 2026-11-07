"""Outer: cancel the public waiter before each real capture transfer command."""
import os
import argparse
from pathlib import Path
import selectors
import socket
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", choices=["eio", "unix"], default="eio")
parser.add_argument("binaries", nargs="+")
args = parser.parse_args()
peer_name = "blocking_cancel_peer" if args.backend == "unix" else "capture_cancel_peer"
peer = root / f"_build/default/test/{peer_name}.exe"
proxy = root / "test/capture_proxy.py"


def readable(stream):
    with selectors.DefaultSelector() as ready:
        ready.register(stream, selectors.EVENT_READ)
        assert ready.select(1), "capture cancellation boundary did not become ready"


for binary in args.binaries:
    with TmuxFixture(binary) as fixture:
        fixture.command("split-window", "-d", "")
        subprocess.run([fixture.binary, "-S", str(fixture.socket), "display-message", "-I", "-t", "%1"],
                       input=b"%end 1 1 1\r\nhello\r\n", capture_output=True, check=True,
                       timeout=1, env=fixture.environment)
        scratch = Path(fixture.directory.name) / "scratch"
        scratch.mkdir()
        fixture.command("set-buffer", "-b", "unrelated", "keep me")
        cases = [("cancel", step) for step in ["capture-pane", "list-buffers", "save-buffer", "delete-buffer"]]
        if args.backend == "eio":
            cases.append(("close", "list-buffers"))
        else:
            cases.append(("deadline", "wait-for"))
        for mode, step in cases:
            path = Path(fixture.directory.name) / "barrier"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                listener.listen(1)
                env = dict(fixture.environment, LIBTMUX_TEST_BINARY=fixture.binary,
                           LIBTMUX_TEST_BARRIER=str(path), LIBTMUX_TEST_CAPTURE_STEP=step)
                process = subprocess.Popen([str(peer), str(proxy), str(fixture.socket), str(scratch), mode],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)
                barrier = None
                try:
                    readable(listener)
                    barrier, _ = listener.accept()
                    readable(barrier)
                    assert barrier.recv(5) == b"HELD\n"
                    process.stdin.write(b"CANCEL\n")
                    process.stdin.flush()
                    readable(process.stdout)
                    expected = b"REQUESTED\n" if args.backend == "unix" else b"CANCELLED\n"
                    assert process.stdout.readline() == expected
                    if mode == "close":
                        readable(process.stdout)
                        assert process.stdout.readline() == b"CLOSING\n"
                    barrier.sendall(b"G")
                    stdout, stderr = process.communicate(timeout=1)
                    assert process.returncode == 0, (step, stdout, stderr)
                    if mode == "close":
                        lines = stdout.splitlines()
                        assert len(lines) == 2 and lines[0].startswith(b"BUFFER libtmux-ocaml-") and lines[1] == b"DRAINED", stdout
                        buffer = lines[0].removeprefix(b"BUFFER ")
                        assert buffer in fixture.command("list-buffers", "-F", "#{buffer_name}").stdout.splitlines()
                        fixture.command("delete-buffer", "-b", buffer)
                    else:
                        expected = b"CANCELLED\nDRAINED\n" if args.backend == "unix" else b"DRAINED\n"
                        assert stdout == expected, stdout
                finally:
                    if barrier is not None:
                        barrier.close()
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=1)
                    for stream in [process.stdin, process.stdout, process.stderr]:
                        stream.close()
            path.unlink()
            assert list(scratch.iterdir()) == []
            assert fixture.command("list-buffers", "-F", "#{buffer_name}").stdout == b"unrelated\n"
            assert fixture.command("list-clients").stdout == b""
        print(f"PASS {Path(binary).parent.name} {args.backend}: cancellation before capture, size read, save and cleanup")
