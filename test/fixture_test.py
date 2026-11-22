"""Outer: real daemons verify owned cleanup on success, failure and cancellation."""

import asyncio
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import patch

from support.tmux_fixture import AMBIENT_SELECTORS, TmuxFixture


def check(binary):
    started = time.monotonic()
    reported = subprocess.run(
        [binary, "-V"], capture_output=True, check=True, text=True
    ).stdout.strip()
    ambient = {
        "TMUX": "/unrelated/server,99999,0",
        "TMUX_PANE": "%99999",
        "LIBTMUX_SOCKET": "ambient-socket",
        "LIBTMUX_SOCKET_PATH": "/unrelated/socket",
    }
    for outcome in (None, RuntimeError, asyncio.CancelledError):
        with patch.dict("os.environ", ambient, clear=False):
            fixture = TmuxFixture(binary)
        assert not (AMBIENT_SELECTORS & fixture.environment.keys())
        try:
            with fixture:
                assert fixture.server is not None
                daemon_env = {
                    entry.split(b"=", 1)[0].decode("latin1")
                    for entry in Path(f"/proc/{fixture.server.pid}/environ")
                    .read_bytes()
                    .split(b"\0")
                    if b"=" in entry
                }
                assert not (AMBIENT_SELECTORS & daemon_env)
                assert (
                    fixture.command("list-sessions", "-F", "#{session_name}").stdout
                    == b"fixture\n"
                )
                connected = (
                    fixture.command("display-message", "-p", "#{version}")
                    .stdout.decode()
                    .strip()
                )
                assert reported == f"tmux {connected}", (reported, connected)
                if outcome:
                    raise outcome()
        except BaseException as error:
            if outcome is None or not isinstance(error, outcome):
                raise
        assert fixture.server is not None
        assert fixture.server.returncode == 0
        assert not Path(fixture.directory.name).exists()
    print(
        f"PASS {Path(binary).parent.name}: success/failure/cancellation cleanup ({time.monotonic() - started:.3f}s)"
    )


if __name__ == "__main__":
    for executable in sys.argv[1:]:
        check(executable)
