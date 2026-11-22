"""Outer: qualify the implemented native components against one exact binary."""

import os
import subprocess
import sys
import time
from pathlib import Path

from support.tmux_fixture import AMBIENT_SELECTORS

root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    raise SystemExit("usage: native_suite.py /path/to/tmux")
binary = str(Path(sys.argv[1]).resolve(strict=True))
clean_env = {k: v for k, v in os.environ.items() if k not in AMBIENT_SELECTORS}
# A driver's deadline is a bound, not a target: far above its run time, so a
# loaded runner does not fail a healthy driver, and finite, so a hung one fails
# the job instead of stalling it.
for name in [
    "fixture",
    "plan",
    "protocol",
    "blocking",
    "binding",
    "capture",
    "eio",
    "capture_cancel",
    "read_process",
    "operations",
    "environment",
    "options",
    "client_operations",
    "terminal",
    "shutdown",
    "streaming",
    "stream_fault",
    "stream_close",
    "bootstrap",
    "private_daemon",
    "default_server",
    "workspace",
]:
    started = time.monotonic()
    subprocess.run(
        [sys.executable, str(root / "test" / f"{name}_test.py"), binary],
        cwd=root,
        env=clean_env,
        check=True,
        timeout=30,
    )
    print(f"PASS {name}: {time.monotonic() - started:.3f}s", flush=True)
subprocess.run(
    [sys.executable, str(root / "test/workspace_test.py"), "--eio", binary],
    cwd=root,
    env=clean_env,
    check=True,
    timeout=5,
)
subprocess.run(
    [sys.executable, str(root / "test/workspace_cli_test.py"), binary],
    cwd=root,
    env=clean_env,
    check=True,
    timeout=5,
)
# Eio's POSIX fallback reaps through switch-owned fibers rather than pidfd
# completion. Exercise cancellation before those fibers' release hooks run.
if os.environ.get("EIO_BACKEND") != "posix":
    for name, arguments in [
        ("eio", []),
        ("binding", []),
        ("capture_cancel", []),
        ("streaming", []),
        ("bootstrap", []),
        ("private_daemon", []),
        ("default_server", []),
        ("workspace", ["--eio"]),
    ]:
        subprocess.run(
            [
                sys.executable,
                str(root / "test" / f"{name}_test.py"),
                *arguments,
                binary,
            ],
            cwd=root,
            check=True,
            timeout=5,
            env=clean_env | {"EIO_BACKEND": "posix"},
        )
        print(f"PASS Eio POSIX lifecycle: {name}", flush=True)
subprocess.run(
    [sys.executable, str(root / "test/pid_race_test.py")],
    cwd=root,
    env=clean_env,
    check=True,
    timeout=5,
)
for backend in ("linux", "posix"):
    subprocess.run(
        [str(root / "_build/default/test/ownership_peer.exe")],
        cwd=root,
        env=clean_env | {"EIO_BACKEND": backend},
        check=True,
        timeout=1,
    )
