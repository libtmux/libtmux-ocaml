"""Outer: reject replacement/malformed read processes and retain cancelled reads."""
from pathlib import Path
import os
import selectors
import socket
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

root = Path(__file__).resolve().parents[1]
peer = root / "_build/default/test/read_process_peer.exe"
proxy = root / "test/read_process_proxy.py"


def readable(stream):
    with selectors.DefaultSelector() as ready:
        ready.register(stream, selectors.EVENT_READ)
        assert ready.select(1), "read-process boundary not ready"


for binary in sys.argv[1:]:
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture, TmuxFixture(binary) as replacement:
            for mode in ["replace", "truncated", "malformed", "oversized", "error", "cancel"]:
                path = Path(fixture.directory.name) / "barrier"
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                    listener.bind(str(path))
                    listener.listen(1)
                    env = dict(fixture.environment, LIBTMUX_TEST_BINARY=fixture.binary,
                               LIBTMUX_TEST_READ_MODE=mode, LIBTMUX_TEST_BARRIER=str(path))
                    executable = fixture.binary if mode == "replace" else str(proxy)
                    process = subprocess.Popen(
                        [str(peer), executable, str(fixture.socket), backend, mode],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        env=env, bufsize=0,
                    )
                    renamed = False
                    try:
                        if mode == "cancel":
                            readable(listener)
                            with listener.accept()[0] as barrier:
                                readable(barrier)
                                assert barrier.recv(5) == b"HELD\n"
                                process.stdin.write(b"CANCEL\n")
                                readable(process.stdout)
                                assert process.stdout.readline() == (b"REQUESTED\n" if backend == "unix" else b"CANCELLED\n")
                                barrier.sendall(b"G")
                        else:
                            readable(process.stdout)
                            assert process.stdout.readline() == b"READY\n"
                            if mode == "replace":
                                backup = fixture.socket.with_name("original")
                                os.rename(fixture.socket, backup)
                                os.rename(replacement.socket, fixture.socket)
                                renamed = True
                            process.stdin.write(b"CONTINUE\n")
                        stdout, stderr = process.communicate(timeout=1)
                        assert process.returncode == 0, (binary, backend, mode, stdout, stderr)
                        assert stdout == (b"DRAINED\n" if mode == "cancel" else b"REJECTED\n"), stdout
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=1)
                        for stream in [process.stdin, process.stdout, process.stderr]:
                            stream.close()
                        if renamed:
                            os.rename(fixture.socket, replacement.socket)
                            os.rename(backup, fixture.socket)
                path.unlink()
                assert fixture.command("list-clients").stdout == b""
                assert replacement.command("list-clients").stdout == b""
                assert fixture.server.poll() is None and replacement.server.poll() is None
            print(f"PASS {Path(binary).parent.name} {backend}: read-process faults and cancellation")
