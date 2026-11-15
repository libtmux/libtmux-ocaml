"""Shared driver for the generators: format OCaml, then write or check files."""

import argparse
import json
import subprocess
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def releases(root: Path = ROOT) -> list[str]:
    """Return the supported tmux releases from catalog/releases.json."""
    return json.loads((root / "catalog/releases.json").read_text())["releases"]


def ocamlformat(root: Path, name: str, source: str, *, interface: bool = False) -> str:
    """Format OCaml source as the file `name`, so `.ocamlformat` applies."""
    return subprocess.run(
        ["ocamlformat", "--name", name, "--intf" if interface else "--impl", "-"],
        input=source,
        text=True,
        capture_output=True,
        check=True,
        cwd=root,
    ).stdout


def main(
    description: str,
    outputs: Callable[[Path], Mapping[str, str]],
    *,
    recapture: tuple[str, Callable[[Path, Path], object]] | None = None,
    argv: Sequence[str] | None = None,
    root: Path = ROOT,
) -> None:
    """Write every generated file, or with `--check` fail if one differs.

    A generator that captures its catalog from upstream sources passes
    `recapture`, the catalog file and a function `(directory, root)` that
    reads the release sources; that adds `--source-dir`.
    """
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--check", action="store_true")
    if recapture:
        parser.add_argument(
            "--source-dir",
            type=Path,
            help="Recapture exact release sources outside check loops",
        )
    args = parser.parse_args(argv)
    if recapture and args.source_dir:
        assert not args.check
        catalog, import_sources = recapture
        (root / catalog).write_text(
            json.dumps(import_sources(args.source_dir, root), indent=2) + "\n"
        )
    for name, content in outputs(root).items():
        path = root / name
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"generated file differs: {name}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
