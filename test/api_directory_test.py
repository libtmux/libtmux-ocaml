"""Outer: owner reference pages keep a complete capability directory.

Usage: python3 test/api_directory_test.py _build/docs/ocaml.json

libtmux.org folds a bold-led paragraph followed by a paragraph or labelled list of
references into one row, and draws a table from three or more rows. This reads the
exported API artifact and requires each owner below to fold into such a table that
names every function and submodule the owner declares.
"""

import json
import re
import sys
from pathlib import Path

OWNERS = [
    "Libtmux.Session",
    "Libtmux.Window",
    "Libtmux.Pane",
    "Libtmux.Operations",
    "Libtmux_unix.Client",
]
MIN_ROWS = 3
LEAD = re.compile(r"\*\*[^*]+?\*\*")
LABEL = re.compile(r"[^:\[`]{1,40}:\s+(.*)", re.DOTALL)
REFERENCE = re.compile(r"\{\{![^{}\s]+\}[^{}]*\}|\{!([^{}\s]+)\}")
KIND = re.compile(r"(?:^|(?<=\.))(?:module-type|type|val|module)-")


def references_only(text: str) -> bool:
    rest = re.sub(r"\band\b", "", REFERENCE.sub("", text))
    return bool(REFERENCE.search(text)) and not re.sub(r"[\s,;.]", "", rest)


def members_block(block: str) -> bool:
    """True for a paragraph of references, or a list of `Label: references` items."""
    if not block.startswith("- "):
        return references_only(block)
    items = re.split(r"\n(?=- )", block)
    labels = [LABEL.fullmatch(item[2:].replace("\n", " ")) for item in items]
    return all(label and references_only(label[1]) for label in labels)


def first_directory(body: str) -> list[str]:
    """The blocks of the first run of three or more rows, as the site folds them."""
    blocks = body.split("\n\n")
    rows, i = [], 0
    while i < len(blocks):
        if (
            LEAD.match(blocks[i])
            and i + 1 < len(blocks)
            and members_block(blocks[i + 1])
        ):
            rows.append(blocks[i + 1])
            i += 2
        elif len(rows) >= MIN_ROWS:
            break
        else:
            rows, i = [], i + 1
    return rows


def problems(owner: str, short: str, members: set[str], body: str) -> list[str]:
    rows = first_directory(body)
    if len(rows) < MIN_ROWS:
        return [f"{owner}: {len(rows)} directory rows, fewer than {MIN_ROWS}"]
    named = {
        KIND.sub("", target)
        for row in rows
        for target in REFERENCE.findall(row)
        if target
    }
    prefix = short + "."
    unknown = sorted(
        name
        for name in named
        if name.startswith(prefix) and name[len(prefix) :] not in members
    )
    missing = sorted(members - {name[len(prefix) :] for name in named})
    return [f"{owner}: directory omits {name}" for name in missing] + [
        f"{owner}: directory names {name}, which is not declared" for name in unknown
    ]


def self_test() -> None:
    body = (
        "Intro.\n\n**One.** See {!O.a}.\n\n{!O.a}\n\n**Two.** Both.\n\n- Left: {!O.b}\n"
        "- Right: {!O.val-c} and {!O.Sub}\n\n**Three.** Three.\n\n{!O.d}, {!O.e}"
    )
    members = {"a", "b", "c", "d", "e", "Sub"}
    assert problems("O", "O", members, body) == []
    assert problems("O", "O", members, body.replace("{!O.d}, ", "")) == [
        "O: directory omits d"
    ]
    assert problems("O", "O", members, body.replace("{!O.d}", "{!O.gone}")) == [
        "O: directory omits d",
        "O: directory names O.gone, which is not declared",
    ]
    assert problems("O", "O", members, body.replace("**Three.**", "Three.")) == [
        "O: 0 directory rows, fewer than 3"
    ]
    assert problems(
        "O", "O", members, body.replace("{!O.d}, {!O.e}", "{!O.d} then text")
    ) == ["O: 0 directory rows, fewer than 3"]


self_test()
artifact = json.loads(Path(sys.argv[1]).read_text())
symbols = {symbol["id"]: symbol for symbol in artifact["symbols"]}
found = []
for owner in OWNERS:
    members = {
        symbol["name"]
        for symbol in artifact["symbols"]
        if symbol.get("parent") == owner and symbol["kind"] in ("function", "module")
    }
    found += problems(
        owner,
        owner.split(".", 1)[1],
        members,
        symbols[owner].get("doc", {}).get("body", ""),
    )
assert not found, "\n".join(found)
print(
    "PASS owner directories: Session, Window, Pane, Operations and Client name every member"
)
