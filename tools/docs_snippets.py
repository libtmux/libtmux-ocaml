"""Check source examples and local links in Markdown documentation."""
import argparse
from pathlib import Path
import re
import textwrap
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
MARKER = re.compile(r"^\s*\(\* docs:(begin|end) ([a-z-]+) \*\)\s*$")
INCLUDE = re.compile(r"<!-- example: ([^\s]+) -->\n\n```(?:ocaml|json)\n(.*?)```", re.DOTALL)
LINK = re.compile(r"(?<!!)\[[^\]]+\]\(([^\s)]+)\)")
ASSET = re.compile(r'\b(?:src|srcset)="([^"\s]+)"')


def anchors(path):
    result = set()
    counts = {}
    fenced = False
    for line in path.read_text().splitlines():
        if line.startswith("```"):
            fenced = not fenced
        if fenced or not line.startswith("#"):
            continue
        heading = line.lstrip("#").strip().lower()
        slug = "".join(c for c in heading if c.isalnum() or c in " _-").replace(" ", "-")
        duplicate = counts.get(slug, 0)
        counts[slug] = duplicate + 1
        result.add(slug + (f"-{duplicate}" if duplicate else ""))
    return result


def snippet(reference):
    name, _, region = reference.partition("#")
    path = (ROOT / name).resolve()
    if not path.is_relative_to(ROOT) or path.suffix not in {".ml", ".json"}:
        raise ValueError(f"invalid example source: {reference}")
    if path.suffix == ".json":
        if region:
            raise ValueError(f"JSON examples include the whole document: {reference}")
        return path.read_text().strip() + "\n"
    lines = path.read_text().splitlines(keepends=True)
    selected = []
    active = not region
    seen = set()
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


def check():
    count = 0
    links = 0
    documents = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]
    documents += [ROOT / package / "README.md" for package in ("lib", "unix", "eio", "json")]
    for document in documents:
        text = document.read_text()
        if text.count("<!-- example:") != len(INCLUDE.findall(text)):
            raise ValueError(f"malformed example include: {document.relative_to(ROOT)}")
        for reference, code in INCLUDE.findall(text):
            if code != snippet(reference):
                raise ValueError(f"example differs: {document.relative_to(ROOT)}: {reference}")
            count += 1
        for destination in LINK.findall(text) + ASSET.findall(text):
            url = urlsplit(destination)
            if url.scheme or url.netloc:
                continue
            path = (document.parent / unquote(url.path)).resolve() if url.path else document
            if not path.is_relative_to(ROOT) or not path.exists():
                raise ValueError(f"broken local link: {document.relative_to(ROOT)}: {destination}")
            if url.fragment and path.suffix == ".md" and unquote(url.fragment) not in anchors(path):
                raise ValueError(f"missing heading: {document.relative_to(ROOT)}: {destination}")
            links += 1
    if not count:
        raise ValueError("documentation has no checked example includes")
    print(f"PASS {count} documentation snippets match executed source")
    print(f"PASS {links} local documentation links and heading targets")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    check()
