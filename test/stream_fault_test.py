"""Outer: real bounded pipe faults exercise the shared stream reader and teardown."""

import subprocess
from pathlib import Path

from support.tmux_fixture import TmuxFixture, test_tmux_binaries

peer = Path(__file__).resolve().parents[1] / "_build/default/test/stream_fault_peer.exe"
for binary in test_tmux_binaries():
    with TmuxFixture(binary) as fixture:
        result = subprocess.run(
            [str(peer), fixture.binary, str(fixture.socket)],
            env=fixture.environment,
            capture_output=True,
            timeout=1,
            check=False,
        )
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert (
            result.stdout
            == b"PASS stream faults, reserved terminal events, budget release and primary isolation\n"
        )
        assert fixture.command("list-clients").stdout == b""
        print(
            f"PASS {Path(binary).parent.name}: shared stream fault reader and retained primary"
        )
