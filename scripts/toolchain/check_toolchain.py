#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check the installed OCaml, dune and opam against the repository's pins."""

import argparse
import re
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

Run = Callable[[list[str]], str]


def pinned_versions(root: Path = ROOT) -> dict[str, str]:
    """Return the exact version each tool is pinned to.

    `ocaml` and `dune` come from the `depends` of `libtmux.opam`, `opam` from
    `.tool-versions`.
    """
    manifest = (root / "libtmux.opam").read_text()
    pins = {}
    for tool in ("ocaml", "dune"):
        match = re.search(rf'^\s*"{tool}" \{{= "([^"]+)"\}}', manifest, re.MULTILINE)
        if match is None:
            raise ValueError(f"libtmux.opam does not pin {tool} with an exact version")
        pins[tool] = match.group(1)
    for line in (root / ".tool-versions").read_text().splitlines():
        name, _, version = line.partition(" ")
        if name == "opam":
            pins["opam"] = version.strip()
    if "opam" not in pins:
        raise ValueError(".tool-versions does not pin opam")
    return pins


def installed_versions(run: Run) -> dict[str, str]:
    """Return the version each tool reports, running opam tools through `opam exec`."""
    return {
        "ocaml": run(["opam", "exec", "--", "ocamlc", "-version"]),
        "dune": run(["opam", "exec", "--", "dune", "--version"]),
        "opam": run(["opam", "--version"]),
    }


def mismatches(pinned: dict[str, str], installed: dict[str, str]) -> list[str]:
    """Describe each tool whose installed version differs from its pin."""
    return [
        f"{tool}: pinned {version}, installed {installed[tool]}"
        for tool, version in pinned.items()
        if installed[tool] != version
    ]


def _run(command: list[str]) -> str:
    return subprocess.run(
        command, check=True, capture_output=True, text=True
    ).stdout.strip()


def main(argv: list[str] | None = None, root: Path = ROOT, run: Run = _run) -> int:
    argparse.ArgumentParser(description=__doc__).parse_args(argv)
    differences = mismatches(pinned_versions(root), installed_versions(run))
    for difference in differences:
        print(difference, file=sys.stderr)
    return 1 if differences else 0


if __name__ == "__main__":
    sys.exit(main())
