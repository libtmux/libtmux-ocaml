"""Outer: real bounded pipe faults exercise the shared stream reader and teardown."""
from pathlib import Path
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/stream_fault_peer.exe"
for binary in sys.argv[1:]:
    with TmuxFixture(binary) as fixture:
        result = subprocess.run([str(peer), fixture.binary, str(fixture.socket)],
                                env=fixture.environment, capture_output=True, timeout=1)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert result.stdout == b"PASS stream faults, reserved terminal events, budget release and primary isolation\n"
        assert fixture.command("list-clients").stdout == b""
        print(f"PASS {Path(binary).parent.name}: shared stream fault reader and retained primary")
