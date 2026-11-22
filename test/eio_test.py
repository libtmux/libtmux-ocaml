"""Outer: real Eio operation ownership at queue, write, acknowledgement and closure."""

import subprocess
from pathlib import Path

from support.tmux_fixture import TmuxFixture, test_tmux_binaries

peer = Path(__file__).resolve().parents[1] / "_build/default/test/eio_peer.exe"
for binary in test_tmux_binaries():
    with TmuxFixture(binary) as fixture:
        fixture.command("split-window", "-d", "")
        subprocess.run(
            [
                fixture.binary,
                "-S",
                str(fixture.socket),
                "display-message",
                "-I",
                "-t",
                "%1",
            ],
            input=b"%end 1 1 1\r\nhello\r\n",
            capture_output=True,
            check=True,
            timeout=1,
            env=fixture.environment,
        )
        result = subprocess.run(
            [str(peer), fixture.binary, str(fixture.socket)],
            capture_output=True,
            timeout=1,
            check=False,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert fixture.command("list-clients").stdout == b""
        assert fixture.command("list-buffers").stdout == b""
        print(
            f"PASS {Path(binary).parent.name}: Eio cancellation, independent drain, client close"
        )
