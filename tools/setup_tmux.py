"""Build exact release fixtures in scratch/tmux; run outside validation loops."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
import time
import tomllib
import urllib.request


PINNED = tomllib.loads((Path(__file__).resolve().parents[1] / ".github/tmux-releases.toml").read_text())["releases"]
VERSIONS = ("3.2a", "3.3", "3.3a", "3.4", "3.8")


def setup(versions):
    root = Path(__file__).resolve().parents[1] / "scratch" / "tmux"
    root.mkdir(parents=True, exist_ok=True)
    records = []
    for version in versions:
        started = time.monotonic()
        url = f"https://github.com/tmux/tmux/releases/download/{version}/tmux-{version}.tar.gz"
        archive = root / f"tmux-{version}.tar.gz"
        record_path = root / f"{version}.json"
        if not archive.exists():
            urllib.request.urlretrieve(url, archive)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        previous = json.loads(record_path.read_text()) if record_path.exists() else None
        expected = PINNED.get(version) or (previous and previous["archive_sha256"])
        if expected is not None and digest != expected:
            raise RuntimeError(f"tmux {version} archive changed")
        source = root / f"tmux-{version}"
        if not source.exists():
            with tarfile.open(archive) as compressed:
                compressed.extractall(root, filter="data")
        binary = source / "tmux"
        if not binary.exists():
            with (root / f"{version}.log").open("w") as log:
                subprocess.run(["./configure", "--disable-dependency-tracking"], cwd=source,
                               stdout=log, stderr=subprocess.STDOUT, check=True)
                subprocess.run(["make", "-j2"], cwd=source, stdout=log,
                               stderr=subprocess.STDOUT, check=True)
        reported = subprocess.check_output([str(binary), "-V"], text=True).strip()
        if reported != f"tmux {version}":
            raise RuntimeError(f"unexpected release: {reported}")
        record = dict(version=reported, url=url, archive_sha256=digest,
                      binary=str(binary.relative_to(root)),
                      binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                      setup_seconds=round(time.monotonic() - started, 3))
        if previous is None:
            record_path.write_text(json.dumps(record, indent=2) + "\n")
        elif record["binary_sha256"] != previous["binary_sha256"]:
            raise RuntimeError(f"tmux {version} binary changed; rebuild evidence required")
        records.append(record)
        print(json.dumps(record), flush=True)
    (root / "matrix.json").write_text(json.dumps(records, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("versions", nargs="*", choices=VERSIONS, default=list(VERSIONS))
    setup(parser.parse_args().versions)
