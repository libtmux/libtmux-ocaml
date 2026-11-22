"""Outer: control-client switching and detach acceptance are separate from peer exit."""

import selectors
import subprocess
from pathlib import Path

from support.tmux_fixture import TmuxFixture, test_tmux_binaries

peer = (
    Path(__file__).resolve().parents[1]
    / "_build/default/test/client_operations_peer.exe"
)
for binary in test_tmux_binaries():
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture:
            fixture.command("new-session", "-d", "-s", "destination", "exec cat")
            fixture.track_panes()
            controlled = subprocess.Popen(
                [
                    fixture.binary,
                    "-u",
                    "-S",
                    str(fixture.socket),
                    "-C",
                    "attach-session",
                    "-f",
                    "no-output",
                    "-t",
                    "fixture",
                    ";",
                    "wait-for",
                    "-S",
                    "client-ready",
                ],
                env=fixture.environment,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert controlled.stdin is not None
            assert controlled.stdout is not None
            assert controlled.stderr is not None
            process = None
            try:
                fixture.command("wait-for", "client-ready")
                process = subprocess.Popen(
                    [
                        str(peer),
                        fixture.binary,
                        str(fixture.socket),
                        backend,
                        str(controlled.pid),
                        fixture.command("display-message", "-p", "#{version}")
                        .stdout.decode()
                        .strip(),
                    ],
                    env=fixture.environment,
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    bufsize=0,
                )
                assert process.stdin is not None
                assert process.stdout is not None
                assert process.stderr is not None
                with selectors.DefaultSelector() as ready:
                    ready.register(process.stdout, selectors.EVENT_READ)
                    assert ready.select(1), "detach request did not finish"
                line = process.stdout.readline()
                assert line == b"DETACH_REQUESTED\n", (line, process.stderr.read())
                controlled.wait(timeout=1)
                assert controlled.returncode == 0, controlled.stderr.read()
                process.stdin.write(b"EXITED\n")
                stdout, stderr = process.communicate(timeout=1)
                assert process.returncode == 0, (binary, backend, stdout, stderr)
                assert (
                    stdout
                    == b"PASS current client names, switch, refresh and detach request\n"
                )
            finally:
                for child in [process, controlled]:
                    if child is not None:
                        if child.poll() is None:
                            child.kill()
                            child.wait(timeout=1)
                        for stream in [child.stdin, child.stdout, child.stderr]:
                            if stream is not None:
                                stream.close()
            assert fixture.command("list-clients").stdout == b""
            print(
                f"PASS {Path(binary).parent.name} {backend}: client operations and peer exit"
            )
