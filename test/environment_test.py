"""Outer: exact environment bytes and scope semantics on both native backends."""
from pathlib import Path
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/environment_peer.exe"
for binary in sys.argv[1:]:
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture:
            result = subprocess.run(
                [str(peer), fixture.binary, str(fixture.socket), backend],
                env=fixture.environment, capture_output=True, timeout=1,
            )
            assert result.returncode == 0, (binary, backend, result.stdout, result.stderr)
            assert result.stdout == b"PASS environment bytes, scopes, hidden values and lifetime\n"
            assert fixture.command("list-clients").stdout == b""
            print(f"PASS {Path(binary).parent.name} {backend}: environment")
