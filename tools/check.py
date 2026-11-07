"""Time a validation command and bind its evidence to the current source tree."""

import argparse
import hashlib
import gzip
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time


def durable_write(path, data):
    with path.open("xb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def source_snapshot(root, directory):
    files = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root,
    ).split(b"\0")
    source = hashlib.sha256()
    packed = io.BytesIO()
    with gzip.GzipFile(fileobj=packed, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for name in sorted(set(files) - {b""}):
                path = root / os.fsdecode(name)
                item = tarfile.TarInfo(os.fsdecode(name))
                item.mode = path.lstat().st_mode & 0o777 if path.exists() or path.is_symlink() else 0
                if path.is_symlink():
                    item.type = tarfile.SYMTYPE
                    item.linkname = os.readlink(path)
                    data = os.fsencode(item.linkname)
                    kind = b"symlink"
                    archive.addfile(item)
                elif path.is_file():
                    data = path.read_bytes()
                    item.size = len(data)
                    kind = b"file"
                    archive.addfile(item, io.BytesIO(data))
                else:
                    data, kind = b"", b"absent"
                source.update(b"\0".join([name, kind, str(item.mode).encode(), data]) + b"\0")
    digest = source.hexdigest()
    content = packed.getvalue()
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / f"{digest}.tar.gz"
    if not target.exists():
        with tempfile.NamedTemporaryFile(dir=directory, prefix=".source-", delete=False) as temporary:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        try:
            try:
                os.link(temporary_path, target)
            except FileExistsError:
                pass
        finally:
            temporary_path.unlink()
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    if target.read_bytes() != content:
        raise RuntimeError("source archive differs for the recorded digest")
    return digest, target, hashlib.sha256(content).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tier", choices=("inner", "mid", "outer"), required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required")
    if args.record.exists():
        raise RuntimeError("evidence exists; choose a new record name")
    root = Path(__file__).resolve().parents[1]
    source, archive, archive_sha256 = source_snapshot(root, args.record.parent / "source-snapshots")
    started = time.monotonic()
    completed = subprocess.run(command, cwd=root, capture_output=True)
    elapsed = time.monotonic() - started
    budget = {"inner": 5, "mid": 30, "outer": 300}[args.tier]
    args.record.parent.mkdir(parents=True, exist_ok=True)
    durable_write(args.record.with_suffix(".log"), completed.stdout + completed.stderr)
    result = dict(command=command, tier=args.tier, seconds=round(elapsed, 4),
                  budget_seconds=budget, exit_code=completed.returncode,
                  status="PASS" if completed.returncode == 0 and elapsed < budget else "FAIL",
                  head=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
                  source_sha256=source, source_hash_version=2,
                  source_archive=str(archive.relative_to(args.record.parent)),
                  source_archive_sha256=archive_sha256)
    durable_write(args.record, (json.dumps(result, indent=2) + "\n").encode())
    print((completed.stdout + completed.stderr).decode(errors="replace"), end="")
    print(f"{result['status']} {args.tier}: {elapsed:.3f}s (budget {budget}s)")
    raise SystemExit(0 if result["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
