"""Outer: native binding, graph capture, domain affinity and release teardown."""
from pathlib import Path
import subprocess
import sys
from support.tmux_fixture import TmuxFixture

peer = Path(__file__).resolve().parents[1] / "_build/default/test/blocking_peer.exe"
for binary in sys.argv[1:]:
    with TmuxFixture(binary) as fixture:
        fixture.command("link-window", "-s", "@0", "-t", "fixture:3")
        fixture.command("rename-window", "-t", "@0", "hostile-%end-λ")
        original = fixture.command("display-message", "-p", "#{pid}").stdout
        result = subprocess.run([str(peer), fixture.binary, str(fixture.socket)],
                                capture_output=True, timeout=1)
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert fixture.command("display-message", "-p", "#{pid}").stdout == original
        assert fixture.command("list-clients", "-F", "#{client_pid}").stdout == b""
        print(result.stdout.decode().strip())
