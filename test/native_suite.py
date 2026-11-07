"""Outer: qualify the implemented native components against one exact binary."""
from pathlib import Path
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
    "client_operations", "terminal", "streaming", "stream_fault", "bootstrap", "workspace",
]:
    started = time.monotonic()
    subprocess.run([sys.executable, str(root / "test" / f"{name}_test.py"), binary],
                   cwd=root, check=True, timeout=30)
    print(f"PASS {name}: {time.monotonic() - started:.3f}s", flush=True)
subprocess.run([sys.executable, str(root / "test/workspace_test.py"), "--eio", binary],
               cwd=root, check=True, timeout=5)
subprocess.run([sys.executable, str(root / "test/workspace_cli_test.py"), binary],
               cwd=root, check=True, timeout=5)
subprocess.run([sys.executable, str(root / "test/pid_race_test.py")],
               cwd=root, check=True, timeout=5)
subprocess.run([sys.executable, str(root / "test/tmux_cache_test.py"), binary],
               cwd=root, check=True, timeout=5)
