#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Check source examples and local links in Markdown documentation."""

import argparse
import re
import textwrap
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
MARKER = re.compile(r"^\s*\(\* docs:(begin|end) ([a-z-]+) \*\)\s*$")
INCLUDE = re.compile(
    r"<!-- example: ([^\s]+) -->\n\n```(?:ocaml|json)\n(.*?)```", re.DOTALL
)
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^\s)]+)\)")
ASSET = re.compile(r'\b(?:src|srcset)="([^"\s]+)"')


def anchors(path: Path) -> set[str]:
    result: set[str] = set()
    counts: dict[str, int] = {}
    fenced = False
    for line in path.read_text().splitlines():
        if line.startswith("```"):
            fenced = not fenced
        if fenced or not line.startswith("#"):
            continue
        heading = line.lstrip("#").strip().lower()
        slug = "".join(c for c in heading if c.isalnum() or c in " _-").replace(
            " ", "-"
        )
        duplicate = counts.get(slug, 0)
        counts[slug] = duplicate + 1
        result.add(slug + (f"-{duplicate}" if duplicate else ""))
    return result


def snippet(reference: str, root: Path = ROOT) -> str:
    """Return the source text a documentation include must repeat.

    A reference is a path relative to the repository root, optionally followed
    by `#region` to select the lines between `docs:begin` and `docs:end`
    markers.
    """
    root = root.resolve()
    name, _, region = reference.partition("#")
    path = (root / name).resolve()
    if not path.is_relative_to(root) or path.suffix not in {".ml", ".json"}:
        raise ValueError(f"invalid example source: {reference}")
    if path.suffix == ".json":
        if region:
            raise ValueError(f"JSON examples include the whole document: {reference}")
        return path.read_text().strip() + "\n"
    lines = path.read_text().splitlines(keepends=True)
    selected = []
    active = not region
    seen: set[str] = set()
    for line in lines:
        marker = MARKER.fullmatch(line.rstrip("\n"))
        if marker:
            kind, label = marker.groups()
            if label == region:
                if kind == "begin":
                    if label in seen or active:
                        raise ValueError(f"duplicate example region: {reference}")
                    seen.add(label)
                    active = True
                else:
                    if not active:
                        raise ValueError(f"unopened example region: {reference}")
                    active = False
            continue
        if active:
            selected.append(line)
    if region and (region not in seen or active):
        raise ValueError(f"missing or unclosed example region: {reference}")
    return textwrap.dedent("".join(selected)).strip() + "\n"


def check(root: Path = ROOT) -> None:
    """Check every documentation include and local link under `root`."""
    root = root.resolve()
    count = 0
    links = 0
    documents = [root / "README.md", *sorted((root / "docs").glob("*.md"))]
    packages = ("lib", "unix", "eio", "json", "workspace", "cli")
    documents += [root / package / "README.md" for package in packages]
    for document in documents:
        text = document.read_text()
        if text.count("<!-- example:") != len(INCLUDE.findall(text)):
            raise ValueError(f"malformed example include: {document.relative_to(root)}")
        for reference, code in INCLUDE.findall(text):
            if code != snippet(reference, root):
                raise ValueError(
                    f"example differs: {document.relative_to(root)}: {reference}"
                )
            count += 1
        for destination in LINK.findall(text) + ASSET.findall(text):
            url = urlsplit(destination)
            if url.scheme or url.netloc:
                continue
            path = (
                (document.parent / unquote(url.path)).resolve()
                if url.path
                else document
            )
            if not path.is_relative_to(root) or not path.exists():
                raise ValueError(
                    f"broken local link: {document.relative_to(root)}: {destination}"
                )
            if (
                url.fragment
                and path.suffix == ".md"
                and unquote(url.fragment) not in anchors(path)
            ):
                raise ValueError(
                    f"missing heading: {document.relative_to(root)}: {destination}"
                )
            links += 1
    if not count:
        raise ValueError("documentation has no checked example includes")
    print(f"PASS {count} documentation snippets match executed source")
    print(f"PASS {links} local documentation links and heading targets")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    check()
