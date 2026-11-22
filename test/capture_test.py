"""Outer: marker-like rendered rows, capture hooks, callback failure and owned cleanup."""

import subprocess
from pathlib import Path

from support.tmux_fixture import TmuxFixture, test_tmux_binaries

peer = Path(__file__).resolve().parents[1] / "_build/default/test/capture_peer.exe"
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
        fixture.command("set-buffer", "-b", "unrelated", "keep me")
        for mode in ["capture", "hooks", "save-error"]:
            if mode == "hooks":
                fixture.command(
                    "set-hook",
                    "-g",
                    "after-capture-pane[17]",
                    "display-message -p HOOK",
                )
            result = subprocess.run(
                [str(peer), fixture.binary, str(fixture.socket), mode],
                capture_output=True,
                timeout=1,
                check=False,
            )
            assert result.returncode == 0, (mode, result.stdout, result.stderr)
            fixture.command("set-hook", "-gu", "after-capture-pane")
            assert (
                fixture.command("list-buffers", "-F", "#{buffer_name}").stdout
                == b"unrelated\n"
            )
            assert fixture.command("list-clients", "-F", "#{client_pid}").stdout == b""
        print(
            f"PASS {Path(binary).parent.name}: private-file capture, hooks, failed-save callback, teardown"
        )
