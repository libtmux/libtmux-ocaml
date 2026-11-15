"""Tests for the documentation snippet and link check."""

import re
import subprocess
import sys
from pathlib import Path

import docs_snippets
import pytest

SCRIPT = Path(docs_snippets.__file__).resolve()
PACKAGES = ("lib", "unix", "eio", "json", "workspace", "cli")

SOURCE = """\
let before = 1
(* docs:begin demo *)
    let answer = 42
(* docs:end demo *)
"""

README = """\
# Demo

Read the [usage guide](docs/guide.md#usage).

<!-- example: examples/demo.ml#demo -->

```ocaml
let answer = 42
```
"""

GUIDE = """\
# Guide

## Usage

Back to the [readme](../README.md).
"""


@pytest.fixture
def tree(tmp_path: Path) -> Path:
    """A minimal passing repository layout."""
    (tmp_path / "README.md").write_text(README)
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs/guide.md").write_text(GUIDE)
    (tmp_path / "examples").mkdir()
    (tmp_path / "examples/demo.ml").write_text(SOURCE)
    for package in PACKAGES:
        (tmp_path / package).mkdir()
        (tmp_path / package / "README.md").write_text(f"# {package}\n")
    docs_snippets.check(tmp_path)
    return tmp_path


def edit(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    assert old in text
    path.write_text(text.replace(old, new))


def test_repository_documentation_passes(capsys: pytest.CaptureFixture[str]) -> None:
    docs_snippets.check()
    assert re.fullmatch(
        r"PASS [1-9]\d* documentation snippets match executed source\n"
        r"PASS [1-9]\d* local documentation links and heading targets\n",
        capsys.readouterr().out,
    )


def test_script_resolves_the_repository_from_its_own_location(tmp_path: Path) -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.startswith("PASS ")


def test_snippet_selects_and_dedents_a_region(tree: Path) -> None:
    assert docs_snippets.snippet("examples/demo.ml#demo", tree) == "let answer = 42\n"
    assert docs_snippets.snippet("examples/demo.ml", tree).startswith("let before")


def test_rejects_include_that_differs_from_source(tree: Path) -> None:
    edit(tree / "README.md", "42", "43")
    with pytest.raises(ValueError, match=r"example differs: README\.md: examples/demo"):
        docs_snippets.check(tree)


def test_rejects_broken_local_link(tree: Path) -> None:
    edit(tree / "docs/guide.md", "../README.md", "../missing.md")
    with pytest.raises(
        ValueError, match=r"broken local link: docs/guide\.md: \.\./missing\.md"
    ):
        docs_snippets.check(tree)


def test_rejects_missing_heading_anchor(tree: Path) -> None:
    edit(tree / "README.md", "#usage", "#nowhere")
    with pytest.raises(
        ValueError, match=r"missing heading: README\.md: docs/guide\.md#nowhere"
    ):
        docs_snippets.check(tree)


def test_rejects_include_without_a_code_block(tree: Path) -> None:
    edit(tree / "README.md", "```ocaml\nlet answer = 42\n```\n", "")
    with pytest.raises(ValueError, match=r"malformed example include: README\.md"):
        docs_snippets.check(tree)


def test_rejects_documentation_without_includes(tree: Path) -> None:
    (tree / "README.md").write_text("# Demo\n")
    with pytest.raises(ValueError, match="no checked example includes"):
        docs_snippets.check(tree)


@pytest.mark.parametrize(
    ("source", "reference", "message"),
    [
        (SOURCE, "examples/demo.ml#absent", "missing or unclosed example region"),
        (
            "(* docs:begin demo *)\nlet x = 1\n",
            "examples/demo.ml#demo",
            "missing or unclosed example region",
        ),
        (
            SOURCE + SOURCE,
            "examples/demo.ml#demo",
            "duplicate example region",
        ),
        (SOURCE, "../outside.ml", "invalid example source"),
        (SOURCE, "README.md", "invalid example source"),
    ],
)
def test_snippet_rejects_invalid_references(
    tree: Path, source: str, reference: str, message: str
) -> None:
    (tree / "examples/demo.ml").write_text(source)
    with pytest.raises(ValueError, match=message):
        docs_snippets.snippet(reference, tree)
