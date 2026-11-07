"""Outer: a live original daemon cannot authorize an auxiliary on its replacement."""
from pathlib import Path
import os
import selectors
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/binding_peer.exe"
for binary in sys.argv[1:]:
    with TmuxFixture(binary) as original, TmuxFixture(binary) as replacement:
        process = subprocess.Popen([str(peer), original.binary, str(original.socket)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout, selectors.EVENT_READ)
                assert ready.select(1), "native binding peer not ready"
            assert process.stdout.readline() == b"READY\n"
            backup = original.socket.with_name("original")
            os.rename(original.socket, backup)
            try:
                os.rename(replacement.socket, original.socket)
                try:
                    process.stdin.write(b"continue\n")
                    process.stdin.flush()
                    stdout, stderr = process.communicate(timeout=1)
                    assert process.returncode == 0, (stdout, stderr)
                    assert stdout == b"REJECT replacement\n"
                    assert original.server.poll() is None and replacement.server.poll() is None
                finally:
                    os.rename(original.socket, replacement.socket)
            finally:
                os.rename(backup, original.socket)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            for stream in [process.stdin, process.stdout, process.stderr]:
                stream.close()
        assert original.command("list-clients").stdout == b""
        assert replacement.command("list-clients").stdout == b""
        print(f"PASS {Path(binary).parent.name}: same-instance auxiliary, replacement rejection, teardown")
