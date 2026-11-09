"""Inner: fixture cleanup failures preserve the triggering error or cancellation."""

import asyncio
import ctypes
import errno
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from support.tmux_fixture import TmuxFixture


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
                    1, ["fixture-cleanup"], output=b"cleanup\x00\xff", stderr=b"cleanup error\xff",
                )
                with self.assertRaises(BaseException) as reported:
                    with EnteredFixture(cleanup):
                        raise primary
                self.assertIs(reported.exception, primary)
                notes = "\n".join(getattr(primary, "__notes__", []))
                for value in (repr(cleanup), repr(cleanup.stdout), repr(cleanup.stderr)):
                    self.assertIn(value, notes)

    def test_success_still_reports_cleanup_failure(self):
        cleanup = OSError("fixture cleanup failed")
        with self.assertRaises(OSError) as reported:
            with EnteredFixture(cleanup):
                pass
        self.assertIs(reported.exception, cleanup)

    def test_setup_failure_survives_cleanup_failure_and_closes_notification(self):
        notification = os.open(os.devnull, os.O_RDONLY | os.O_CLOEXEC)
        libc = SimpleNamespace(inotify_init1=lambda _: notification, inotify_add_watch=lambda *_: -1)
        fixture = TmuxFixture.__new__(TmuxFixture)
        fixture.directory = SimpleNamespace(name=Path("owned-fixture"))
        cleanup = RuntimeError("fixture cleanup failed")
        with patch("support.tmux_fixture.ctypes.CDLL", return_value=libc), \
                patch.object(TmuxFixture, "close", side_effect=cleanup):
            ctypes.set_errno(errno.EACCES)
            with self.assertRaises(BaseException) as reported:
                fixture.__enter__()
        self.assertIsInstance(reported.exception, OSError)
        self.assertEqual(reported.exception.errno, errno.EACCES)
        self.assertIn(repr(cleanup), "\n".join(reported.exception.__notes__))
        with self.assertRaises(OSError) as closed:
            os.fstat(notification)
        self.assertEqual(closed.exception.errno, errno.EBADF)


if __name__ == "__main__":
    unittest.main()
