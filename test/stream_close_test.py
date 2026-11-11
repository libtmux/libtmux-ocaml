"""Outer: closing a subscription while its pane prints must not kill the tmux daemon."""
from pathlib import Path
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/stream_close_peer.exe"
for binary in sys.argv[1:]:
    with TmuxFixture(binary) as fixture:
        result = subprocess.run([str(peer), fixture.binary, str(fixture.socket), "100"],
                                env=fixture.environment, capture_output=True, timeout=10)
        assert result.returncode == 0, (binary, result.stdout, result.stderr)
        assert result.stdout == b"PASS subscriptions closed mid-output\n", result.stdout
        assert fixture.command("list-clients").stdout == b""
        print(f"PASS {Path(binary).parent.name}: subscriptions closed mid-output leave the daemon running")
