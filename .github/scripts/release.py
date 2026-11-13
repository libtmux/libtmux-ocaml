"""Validate release identity and retain checksums for the opam artifact set."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


PACKAGES = (
    "libtmux", "libtmux-eio", "libtmux-json", "libtmux-unix",
    "libtmux-workspace", "libtmux-workspace-cli",
)


def git(*arguments):
    return subprocess.check_output(["git", *arguments], text=True, stderr=subprocess.PIPE).strip()


def metadata(tag, publish):
    match = re.search(r"^\(version ([0-9]+\.[0-9]+\.[0-9]+)\)$", Path("dune-project").read_text(), re.M)
    if match is None:
        raise ValueError("dune-project must declare a numeric release version")
    version = match[1]
    expected_tag = f"v{version}"
    if tag and tag != expected_tag:
        raise ValueError(f"tag {tag!r} disagrees with package version {version}")
    packages = sorted(path.stem for path in Path(".").glob("*.opam"))
    if packages != list(PACKAGES):
        raise ValueError("release requires the complete libtmux package set")
    for package in PACKAGES:
        declared = re.search(r'^version:\s*"([^"]+)"', Path(f"{package}.opam").read_text(), re.M)
        if declared and declared[1] != version:
            raise ValueError(f"{package} version disagrees with dune-project")
    changelog = Path("CHANGELOG.md").read_text()
    section = re.search(
        rf"^## v?{re.escape(version)}(?: \([^\n]+\))?\n(.*?)(?=^## |\Z)",
        changelog, re.M | re.S,
    )
    if section is None or not section[1].strip():
        raise ValueError(f"changelog needs release notes for {version}")
    commit = git("rev-parse", "HEAD")
    if publish:
        if not tag or git("cat-file", "-t", f"refs/tags/{tag}") != "tag":
            raise ValueError("publishing requires an annotated release tag")
        if git("rev-parse", f"refs/tags/{tag}^{{commit}}") != commit:
            raise ValueError("release tag must identify HEAD")
        if subprocess.run(["git", "merge-base", "--is-ancestor", "HEAD", "origin/master"]).returncode:
            raise ValueError("release commit must already be merged into origin/master")
    if subprocess.run(["git", "diff", "--quiet", "HEAD", "--"]).returncode:
        raise ValueError("commit tracked changes before building the release")
    notes = re.sub(
        r"\]\((?![a-z]+:|#|/)([^)]+)\)",
        lambda link: f"](https://github.com/libtmux/libtmux-ocaml/blob/{commit}/{link[1]})",
        section[1].strip(),
    )
    return {
        "version": version, "tag": expected_tag, "commit": commit,
        "packages": packages, "notes": notes + "\n",
    }


def artifact_paths(release):
    version = release["version"]
    return [
        "release.json", "RELEASE_NOTES.md", f"libtmux-v{version}.tbz",
        *(f"{package}.{version}/opam" for package in release["packages"]),
    ]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def retained(directory, tag, publish, seal):
    release = json.loads((directory / "release.json").read_text())
    current = metadata(tag, publish)
    if release != current:
        raise ValueError("retained release identity differs from the current version or commit")
    if seal:
        (directory / "RELEASE_NOTES.md").write_text(release["notes"])
        checksums = "".join(f"{digest(directory / name)}  {name}\n" for name in artifact_paths(release))
        (directory / "SHA256SUMS").write_text(checksums)
    else:
        expected = {name: digest(directory / name) for name in artifact_paths(release)}
        recorded = {}
        for line in (directory / "SHA256SUMS").read_text().splitlines():
            checksum, name = line.split("  ", 1)
            if name in recorded:
                raise ValueError("duplicate retained checksum")
            recorded[name] = checksum
        if recorded != expected:
            raise ValueError("retained release checksum mismatch")
    return release


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "seal", "verify"))
    parser.add_argument("--tag", default="")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    args = parser.parse_args()
    try:
        release = (
            metadata(args.tag, args.publish) if args.command == "check"
            else retained(args.directory, args.tag, args.publish, args.command == "seal")
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release: {error}\n")
    print(json.dumps(release, indent=2))


if __name__ == "__main__":
    main()
