"""Outer: check bounded regular-file and piped workspace input on both Eio backends."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--directory", type=Path, help="Parent directory on the filesystem to exercise")
parser.add_argument("--cli", type=Path, default=root / "_build/default/cli/main.exe")
args = parser.parse_args()
raw = json.dumps({"schema": "libtmux.workspace/1", "session": "document-check",
                  "windows": [{"name": "editor", "panes": [{}]}]}).encode()
failures = []
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-document-", dir=args.directory) as directory:
    path = Path(directory) / "workspace with spaces.json"
    for backend in ["linux", "posix"]:
        environment = dict(os.environ, EIO_BACKEND=backend,
                           TMUX="/unrelated/server,99999,0", TMUX_PANE="%99999")
        for size in [len(raw), 65_536, 65_537]:
            document = raw + b" " * (size - len(raw))
            path.write_bytes(document)
            for source in ["file", "pipe"]:
                filename = path if source == "file" else Path("/dev/stdin")
                result = subprocess.run([str(args.cli), "check", "--json", str(filename)],
                                        env=environment, input=document if source == "pipe" else b"",
                                        capture_output=True, timeout=1)
                expected = 0 if size <= 65_536 else 2
                output = json.loads(result.stdout)
                valid = result.returncode == expected and not result.stderr
                if expected == 0:
                    valid = valid and output.get("document_digest") == (
                        "blake2b-256:" + hashlib.blake2b(document, digest_size=32).hexdigest())
                    valid = valid and output.get("session") == "document-check"
                else:
                    valid = valid and output.get("error", {}).get("message") == "document exceeds 64 KiB"
                if not valid:
                    failures.append((backend, source, size, result.returncode, output, result.stderr))
assert not failures, failures
print("PASS regular documents and piped input on Eio linux/posix; 64 KiB inclusive")
