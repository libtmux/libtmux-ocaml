"""Build and validate the private tmux installation used by GitHub Actions."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import tempfile
import tomllib

_REPOSITORY = "https://github.com/tmux/tmux.git"
with (pathlib.Path(__file__).parents[1] / "tmux-releases.toml").open("rb") as _pins:
    _RELEASES: dict[str, str] = tomllib.load(_pins)["releases"]

_BUILD_ENV = {
    "CC": "cc",
    "CFLAGS": "-O2",
    "CPPFLAGS": "",
    "LDFLAGS": "",
    "MAKEFLAGS": "",
}


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _output(args: list[str]) -> str:
    return subprocess.run(
        args, check=True, capture_output=True, text=True
    ).stdout.strip()


def _resolve(ref: str) -> str:
    """Resolve a tag, branch or commit to the commit it names."""
    if re.fullmatch(r"[0-9a-f]{40}", ref):
        return ref
    names = [f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", f"refs/heads/{ref}"]
    listing = _output(["git", "ls-remote", "--", _REPOSITORY, *names])
    found = dict(reversed(line.split()) for line in listing.splitlines())
    for name in names:
        if name in found:
            return found[name]
    msg = f"{_REPOSITORY} has no tag or branch named {ref}"
    raise ValueError(msg)


def _identity(version: str) -> dict[str, str]:
    parts = [os.environ.get(name, "") for name in ("ImageOS", "ImageVersion")]
    if not all(re.fullmatch(r"[A-Za-z0-9_.-]+", part) for part in parts):
        msg = "Missing or invalid runner image identity"
        raise ValueError(msg)
    image = "-".join(parts)
    source = _RELEASES.get(version)
    if source is None:
        source = _resolve(version)
    return {
        "version": version,
        "source": source,
        "image": image,
        "arch": platform.machine(),
        "recipe": _sha256(pathlib.Path(__file__)),
        "fixture": _sha256(pathlib.Path(__file__).parents[2] / "test/support/tmux_fixture.py"),
        "compiler": _output(["cc", "--version"]),
        "packages": _output(
            [
                "dpkg-query",
                "-W",
                "-f=${Package}=${Version}\n",
                "gcc",
                "libc6",
                "libevent-dev",
                "libncurses-dev",
                "libutempter-dev",
                "bison",
                "autoconf",
                "automake",
                "pkg-config",
            ]
        ),
    }


def _cache_key(identity: dict[str, str]) -> str:
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    return f"tmux-v2-{identity['version']}-{digest}"


def _probe(binary: pathlib.Path, version: str) -> None:
    import sys
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "test"))
    from support.tmux_fixture import TmuxFixture
    reported = _output([str(binary), "-V"])
    if version in _RELEASES and reported != f"tmux {version}":
        raise ValueError(f"Expected tmux {version}, got {reported!r}")
    with TmuxFixture(binary) as fixture:
        connected = fixture.command("display-message", "-p", "#{version}").stdout.decode().strip()
        if reported != f"tmux {connected}":
            raise ValueError(f"Connected daemon version differs: {connected!r}")


def _valid(prefix: pathlib.Path, identity: dict[str, str]) -> bool:
    binary = prefix / "bin" / "tmux"
    try:
        if prefix.is_symlink() or binary.parent.is_symlink() or binary.is_symlink():
            return False
        record = json.loads((prefix / "build.json").read_text())
        if record != {"identity": identity, "sha256": _sha256(binary)}:
            return False
        _probe(binary, identity["version"])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"tmux cache rejected: {error}", flush=True)
        return False
    return True


def _build(prefix: pathlib.Path, identity: dict[str, str]) -> None:
    env = dict(os.environ, **_BUILD_ENV)
    with tempfile.TemporaryDirectory(
        prefix="tmux-source-", dir=prefix.parent
    ) as temporary:
        work = pathlib.Path(temporary)
        version = identity["version"]
        if version not in _RELEASES:
            source = work / "tmux"
            subprocess.run(["git", "init", str(source)], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "fetch",
                    "--depth=1",
                    _REPOSITORY,
                    identity["source"],
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(source), "checkout", "--detach", "FETCH_HEAD"],
                check=True,
            )
            if (
                _output(["git", "-C", str(source), "rev-parse", "HEAD"])
                != identity["source"]
            ):
                msg = "Fetched tmux commit differs from the cache identity"
                raise ValueError(msg)
            subprocess.run(["sh", "autogen.sh"], check=True, cwd=source, env=env)
        else:
            archive = work / "tmux.tar.gz"
            subprocess.run(
                [
                    "curl",
                    "--fail",
                    "--location",
                    "--retry",
                    "2",
                    "--output",
                    str(archive),
                    f"https://github.com/tmux/tmux/releases/download/{version}/tmux-{version}.tar.gz",
                ],
                check=True,
            )
            if _sha256(archive) != identity["source"]:
                msg = "Downloaded tmux archive does not match its pinned SHA256"
                raise ValueError(msg)
            subprocess.run(
                [
                    "tar",
                    "--extract",
                    "--gzip",
                    "--file",
                    str(archive),
                    "--directory",
                    str(work),
                    "--no-same-owner",
                    "--no-same-permissions",
                ],
                check=True,
            )
            source = work / f"tmux-{version}"
        subprocess.run(
            ["./configure", f"--prefix={prefix}"], check=True, cwd=source, env=env
        )
        jobs = min(4, len(os.sched_getaffinity(0)))
        subprocess.run(["make", f"-j{jobs}"], check=True, cwd=source, env=env)
        subprocess.run(["make", "install"], check=True, cwd=source, env=env)


def _prepare(prefix: pathlib.Path, identity: dict[str, str]) -> bool:
    if _valid(prefix, identity):
        print(f"Validated cached tmux {identity['version']}", flush=True)
        return False
    if prefix.is_symlink():
        prefix.unlink()
    elif prefix.exists():
        shutil.rmtree(prefix)
    _build(prefix, identity)
    binary = prefix / "bin" / "tmux"
    _probe(binary, identity["version"])
    (prefix / "build.json").write_text(
        json.dumps(
            {
                "identity": identity,
                "sha256": _sha256(binary),
            },
            sort_keys=True,
        )
        + "\n"
    )
    return True


def _name(version: str) -> str:
    """Name the directory for a release, tag, branch or commit."""
    if version in _RELEASES:
        return f"tmux-{version}"
    digest = hashlib.sha256(version.encode()).hexdigest()[:8]
    return f"tmux-{re.sub(r'[^A-Za-z0-9.-]', '_', version)}-{digest}"


def _main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=["plan", "prepare"])
    parser.add_argument("version", help="a release, tag, branch or 40-hex commit")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9._/-]{1,64}", args.version) or (
        args.version.startswith("-")
    ):
        parser.error(f"not a tmux ref: {args.version}")
    root = pathlib.Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    prefix = root / _name(args.version)
    plan = root / f"{_name(args.version)}.json"
    if args.phase == "plan":
        identity = _identity(args.version)
        plan.write_text(json.dumps(identity, sort_keys=True) + "\n")
        print(json.dumps(identity, indent=2), flush=True)
        with pathlib.Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(f"prefix={prefix}\nkey={_cache_key(identity)}\n")
    else:
        identity = json.loads(plan.read_text())
        if identity["version"] != args.version:
            msg = "Build plan version does not match the requested tmux"
            raise ValueError(msg)
        rebuilt = _prepare(prefix, identity)
        if rebuilt and os.environ.get("CACHE_HIT") == "true":
            print(
                "::warning::Invalid exact cache rebuilt locally. Change the build "
                "recipe to invalidate the immutable cache entry on subsequent runs."
            )


if __name__ == "__main__":
    _main()
