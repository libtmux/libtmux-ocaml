"""Inner: fixture cleanup failures preserve the triggering error or cancellation."""

import asyncio
import ctypes
import errno
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from support.tmux_fixture import (
    AMBIENT_SELECTORS,
    LEGACY_TEST_TMUX_ENV,
    TEST_TMUX_ENV,
    TmuxFixture,
    configured_test_tmux,
    resolve_test_tmux,
    test_tmux_binaries,
)


class EnteredFixture(TmuxFixture):
    """Exercise context exit without starting a daemon."""

    def __init__(self, cleanup):
        self.cleanup = cleanup

    def __enter__(self):
        return self

    def close(self):
        raise self.cleanup


class FixtureDiagnostics(unittest.TestCase):
    def test_body_failure_and_cancellation_keep_their_identity(self):
        for primary in (RuntimeError("consumer failed"), asyncio.CancelledError()):
            with self.subTest(primary=type(primary).__name__):
                cleanup = subprocess.CalledProcessError(
                    1,
                    ["fixture-cleanup"],
                    output=b"cleanup\x00\xff",
                    stderr=b"cleanup error\xff",
                )
                with (
                    self.assertRaises(BaseException) as reported,
                    EnteredFixture(cleanup),
                ):
                    raise primary
                self.assertIs(reported.exception, primary)
                notes = "\n".join(getattr(primary, "__notes__", []))
                for value in (
                    repr(cleanup),
                    repr(cleanup.stdout),
                    repr(cleanup.stderr),
                ):
                    self.assertIn(value, notes)

    def test_success_still_reports_cleanup_failure(self):
        cleanup = OSError("fixture cleanup failed")
        with self.assertRaises(OSError) as reported, EnteredFixture(cleanup):
            pass
        self.assertIs(reported.exception, cleanup)

    def test_setup_failure_survives_cleanup_failure_and_closes_notification(self):
        notification = os.open(os.devnull, os.O_RDONLY | os.O_CLOEXEC)
        libc = SimpleNamespace(
            inotify_init1=lambda _: notification, inotify_add_watch=lambda *_: -1
        )
        fixture = TmuxFixture.__new__(TmuxFixture)
        fixture.directory = SimpleNamespace(name=Path("owned-fixture"))  # ty: ignore[invalid-assignment]  # test double
        cleanup = RuntimeError("fixture cleanup failed")
        with (
            patch("support.tmux_fixture.ctypes.CDLL", return_value=libc),
            patch.object(TmuxFixture, "close", side_effect=cleanup),
        ):
            ctypes.set_errno(errno.EACCES)
            with self.assertRaises(BaseException) as reported:
                fixture.__enter__()
        error = reported.exception
        assert isinstance(error, OSError), error
        self.assertEqual(error.errno, errno.EACCES)
        self.assertIn(repr(cleanup), "\n".join(error.__notes__))
        with self.assertRaises(OSError) as closed:
            os.fstat(notification)
        self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_ambient_selectors_are_scrubbed(self):
        injected = {
            "TMUX": "/unrelated/server,99999,0",
            "TMUX_PANE": "%99999",
            "LIBTMUX_SOCKET": "ambient-socket",
            "LIBTMUX_SOCKET_PATH": "/unrelated/socket",
            TEST_TMUX_ENV: "/bin/sh",
        }
        with patch.dict(os.environ, injected, clear=False):
            fixture = TmuxFixture()
            try:
                self.assertEqual(AMBIENT_SELECTORS & fixture.environment.keys(), set())
                self.assertEqual(fixture.environment.get(TEST_TMUX_ENV), "/bin/sh")
                self.assertEqual(
                    fixture.binary, str(Path("/bin/sh").resolve(strict=True))
                )
            finally:
                fixture.close()

    def test_executable_resolution_precedence_and_fallbacks(self):
        with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-exec-") as root_raw:
            root = Path(root_raw)
            path_dir = root / "bin"
            path_dir.mkdir()
            spaced_dir = root / " spaced "
            spaced_dir.mkdir()

            def make_executable(target: Path) -> str:
                target.write_bytes(b"#!/bin/sh\nexit 0\n")
                target.chmod(0o700)
                return str(target.resolve(strict=True))

            primary = make_executable(root / "primary-tmux")
            legacy = make_executable(root / "legacy-tmux")
            on_path = make_executable(path_dir / "tmux")
            named = make_executable(path_dir / "custom-tmux")
            explicit = make_executable(root / "explicit-tmux")
            spaced = make_executable(spaced_dir / "tmux ")

            both = {
                TEST_TMUX_ENV: primary,
                LEGACY_TEST_TMUX_ENV: legacy,
                "PATH": str(path_dir),
            }
            self.assertEqual(configured_test_tmux(both), primary)
            self.assertEqual(resolve_test_tmux(env=both), primary)
            self.assertEqual(test_tmux_binaries([], env=both), [primary])

            for blank in ("", "   ", "\t\n "):
                fallback_legacy = {
                    TEST_TMUX_ENV: blank,
                    LEGACY_TEST_TMUX_ENV: legacy,
                    "PATH": str(path_dir),
                }
                self.assertEqual(configured_test_tmux(fallback_legacy), legacy)
                self.assertEqual(resolve_test_tmux(env=fallback_legacy), legacy)

                fallback_path = {
                    TEST_TMUX_ENV: blank,
                    LEGACY_TEST_TMUX_ENV: blank,
                    "PATH": str(path_dir),
                }
                self.assertIsNone(configured_test_tmux(fallback_path))
                self.assertEqual(resolve_test_tmux(env=fallback_path), on_path)
                self.assertEqual(test_tmux_binaries([], env=fallback_path), [on_path])

            named_env = {TEST_TMUX_ENV: "custom-tmux", "PATH": str(path_dir)}
            self.assertEqual(resolve_test_tmux(env=named_env), named)

            untrimmed_raw = str(spaced_dir / "tmux ")
            self.assertEqual(
                resolve_test_tmux(env={TEST_TMUX_ENV: untrimmed_raw, "PATH": ""}),
                spaced,
            )

            broken_env = {
                TEST_TMUX_ENV: str(root / "missing-tmux"),
                LEGACY_TEST_TMUX_ENV: legacy,
                "PATH": str(path_dir),
            }
            with self.assertRaises(FileNotFoundError):
                resolve_test_tmux(env=broken_env)
            self.assertEqual(resolve_test_tmux(explicit, env=broken_env), explicit)
            self.assertEqual(test_tmux_binaries([explicit], env=broken_env), [explicit])
            with self.assertRaises(FileNotFoundError) as missing_path:
                resolve_test_tmux(env={"PATH": str(root)})
            self.assertIn(TEST_TMUX_ENV, str(missing_path.exception))


if __name__ == "__main__":
    unittest.main()
