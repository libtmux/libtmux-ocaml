"""Outer: native option scopes, exact bytes and array/inheritance behavior."""
from pathlib import Path
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/options_peer.exe"
for binary in sys.argv[1:]:
    for backend in ["unix", "eio"]:
        with TmuxFixture(binary) as fixture:
            result = subprocess.run(
                [str(peer), fixture.binary, str(fixture.socket), backend],
                env=fixture.environment, capture_output=True, timeout=1,
            )
            assert result.returncode == 0, (binary, backend, result.stdout, result.stderr)
            assert result.stdout == b"PASS options, byte fidelity, scopes, arrays and inheritance\n"
            assert fixture.command("list-clients").stdout == b""
            assert fixture.command("show-environment", "-g", "LIBTMUX_HOOK_BEFORE_FAILURE").stdout == b"LIBTMUX_HOOK_BEFORE_FAILURE=retained\n"
            assert fixture.command("show-environment", "-g", "LIBTMUX_HOOK_AFTER_FAILURE", check=False).returncode != 0
            print(f"PASS {Path(binary).parent.name} {backend}: options")
