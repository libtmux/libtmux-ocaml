"""Outer: deterministic PID acquisition/recheck faults using real child processes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
peer = root / "_build/default/test/pid_race_peer.exe"
fake = root / "test/pid_race_tmux.py"
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-pid-race-") as directory:
    for mode in ["exit-before-open", "exit-before-recheck", "changed-pid", "malformed-after-write"]:
        receipt = Path(directory) / f"{mode}.json"
        env = dict(os.environ, LIBTMUX_TEST_PID_RACE=mode, LIBTMUX_TEST_PID_RECEIPT=str(receipt))
        result = subprocess.run([str(peer), str(fake)], capture_output=True, timeout=1, env=env)
        assert result.returncode == 0, (mode, result.stdout, result.stderr)
        proof = json.loads(receipt.read_text())
        assert proof["reaped"] and proof["identities"] == (1 if mode == "exit-before-open" else 2), proof
        print(f"PASS {mode}: rejected, descriptors closed, owned child reaped")
