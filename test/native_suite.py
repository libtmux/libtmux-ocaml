"""Outer: qualify the implemented native components against one exact binary."""
from pathlib import Path
import os
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
if len(sys.argv) != 2:
    raise SystemExit("usage: native_suite.py /path/to/tmux")
binary = str(Path(sys.argv[1]).resolve(strict=True))
for name in [
    "fixture", "plan", "protocol", "blocking", "binding", "capture", "eio",
    "capture_cancel", "read_process", "operations", "environment", "options",
    "client_operations", "terminal", "shutdown", "streaming", "stream_fault", "stream_close", "bootstrap", "workspace",
]:
    started = time.monotonic()
    subprocess.run([sys.executable, str(root / "test" / f"{name}_test.py"), binary],
                   cwd=root, check=True, timeout=30)
    print(f"PASS {name}: {time.monotonic() - started:.3f}s", flush=True)
subprocess.run([sys.executable, str(root / "test/workspace_test.py"), "--eio", binary],
               cwd=root, check=True, timeout=5)
subprocess.run([sys.executable, str(root / "test/workspace_cli_test.py"), binary],
               cwd=root, check=True, timeout=5)
# Eio's POSIX fallback reaps through switch-owned fibers rather than pidfd
# completion. Exercise cancellation before those fibers' release hooks run.
if os.environ.get("EIO_BACKEND") != "posix":
    for name, arguments in [("eio", []), ("binding", []), ("capture_cancel", []), ("streaming", []),
                            ("bootstrap", []), ("workspace", ["--eio"])]:
        subprocess.run([sys.executable, str(root / "test" / f"{name}_test.py"),
                        *arguments, binary], cwd=root, check=True, timeout=5,
                       env=os.environ | {"EIO_BACKEND": "posix"})
        print(f"PASS Eio POSIX lifecycle: {name}", flush=True)
subprocess.run([sys.executable, str(root / "test/pid_race_test.py")],
               cwd=root, check=True, timeout=5)
for backend in ("linux", "posix"):
    subprocess.run([str(root / "_build/default/test/ownership_peer.exe")],
                   cwd=root, env=os.environ | {"EIO_BACKEND": backend}, check=True, timeout=1)
subprocess.run([sys.executable, str(root / "test/tmux_cache_test.py"), binary],
               cwd=root, check=True, timeout=5)
