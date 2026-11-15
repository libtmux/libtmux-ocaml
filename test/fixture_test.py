"""Outer: real daemons verify owned cleanup on success, failure and cancellation."""

import asyncio
import subprocess
import sys
import time
from pathlib import Path

from support.tmux_fixture import TmuxFixture


def check(binary):
    started = time.monotonic()
    reported = subprocess.run(
        [binary, "-V"], capture_output=True, check=True, text=True
    ).stdout.strip()
    for outcome in (None, RuntimeError, asyncio.CancelledError):
        fixture = TmuxFixture(binary)
        try:
            with fixture:
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
