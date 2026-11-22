"""Outer: real daemons verify owned cleanup on success, failure and cancellation."""

import asyncio
import subprocess
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

from support.tmux_fixture import (
    AMBIENT_SELECTORS,
    LEGACY_TEST_TMUX_ENV,
    TEST_TMUX_ENV,
    TmuxFixture,
    resolve_test_tmux,
    test_tmux_binaries,
)


def check_executable_selection():
    with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-select-") as raw_dir:
        root = Path(raw_dir)
        path_dir = root / "path"
        path_dir.mkdir()
        entries = {}
        for name, target in (
            ("primary", root / "primary-tmux"),
            ("legacy", root / "legacy-tmux"),
            ("path", path_dir / "tmux"),
            ("explicit", root / "explicit-tmux"),
        ):
            target.write_bytes(b"#!/bin/sh\nexit 0\n")
            target.chmod(0o700)
            entries[name] = str(target.resolve(strict=True))
        env = {
            TEST_TMUX_ENV: entries["primary"],
            LEGACY_TEST_TMUX_ENV: entries["legacy"],
            "PATH": str(path_dir),
        }
        assert resolve_test_tmux(env=env) == entries["primary"]
        assert (
            resolve_test_tmux(env={**env, TEST_TMUX_ENV: "  \t "}) == entries["legacy"]
        )
        assert (
            resolve_test_tmux(
                env={
                    TEST_TMUX_ENV: "",
                    LEGACY_TEST_TMUX_ENV: " ",
                    "PATH": str(path_dir),
                }
            )
            == entries["path"]
        )
        assert (
            resolve_test_tmux(
                entries["explicit"], env={**env, TEST_TMUX_ENV: "/nonexistent/tmux"}
            )
            == entries["explicit"]
        )
        assert test_tmux_binaries([entries["explicit"]], env=env) == [
            entries["explicit"]
        ]


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
        TEST_TMUX_ENV: binary,
        LEGACY_TEST_TMUX_ENV: "/nonexistent/legacy-tmux",
    }
    for outcome in (None, RuntimeError, asyncio.CancelledError):
        with patch.dict("os.environ", ambient, clear=False):
            fixture = TmuxFixture()
        assert not (AMBIENT_SELECTORS & fixture.environment.keys())
        assert fixture.environment.get(TEST_TMUX_ENV) == binary
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
    check_executable_selection()
    for executable in test_tmux_binaries():
        check(executable)
