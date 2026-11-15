"""Tests for the catalog and operation generators.

Each generator runs on the repository and on temporary copies of the files it
reads and writes. The generators format OCaml with `ocamlformat`, which must be
on PATH; run the tests under `opam exec --`.
"""

import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

import generate_fields
import generate_formats
import generate_operations
import generate_options
import pytest

REPOSITORY = Path(__file__).resolve().parents[3]


@dataclass(frozen=True)
class Generator:
    name: str
    main: Callable[[Sequence[str] | None, Path], None]
    reads: tuple[str, ...]
    writes: tuple[str, ...]
    # Changing `old` to `new` in `changed` must change the generated files.
    changed: str
    old: str
    new: str


FIELDS = Generator(
    "fields",
    generate_fields.main,
    ("catalog/fields.json",),
    ("lib/generated_fields.ml", "docs/fields.md"),
    "catalog/fields.json",
    '"session_name"',
    '"session_namex"',
)
GENERATORS = [
    FIELDS,
    Generator(
        "formats",
        generate_formats.main,
        ("catalog/releases.json", "catalog/formats.json"),
        ("lib/format_catalog.ml", "docs/formats.md"),
        "catalog/formats.json",
        '"name": "',
        '"name": "x',
    ),
    Generator(
        "options",
        generate_options.main,
        ("catalog/releases.json", "catalog/options.json"),
        ("lib/option_catalog.ml", "docs/options.md"),
        "catalog/options.json",
        '"name": "',
        '"name": "x',
    ),
    Generator(
        "operations",
        generate_operations.main,
        ("lib/libtmux.mli", "lib/commands.ml"),
        (
            "catalog/operations.json",
            "docs/operations.md",
            "unix/generated_operations.ml",
            "unix/libtmux_unix.mli",
            "eio/generated_operations.ml",
            "eio/libtmux_eio.mli",
        ),
        "lib/libtmux.mli",
        "Capture and validate the complete",
        "Capture and validate the whole",
    ),
]
IDS = [generator.name for generator in GENERATORS]
WITH_RELEASES = [g for g in GENERATORS if "catalog/releases.json" in g.reads]


@pytest.fixture(scope="session", autouse=True)
def ocamlformat() -> None:
    if shutil.which("ocamlformat"):
        return
    message = "ocamlformat is not on PATH; run the tests under `opam exec --`"
    if os.environ.get("CI"):
        pytest.fail(message)
    pytest.skip(message)


@pytest.fixture(scope="session")
def pristine(tmp_path_factory: pytest.TempPathFactory) -> Callable[[Generator], Path]:
    """Copy the files a generator reads and writes once, and prove the copy passes."""
    copies: dict[str, Path] = {}

    def build(generator: Generator) -> Path:
        if generator.name not in copies:
            directory = tmp_path_factory.mktemp(generator.name)
            names = (
                ".ocamlformat",
                "dune-project",
                *generator.reads,
                *generator.writes,
            )
            for name in names:
                target = directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPOSITORY / name, target)
            generator.main(["--check"], directory)
            copies[generator.name] = directory
        return copies[generator.name]

    return build


@dataclass
class Tree:
    """A private, modifiable copy of a generator's files."""

    path: Path
    generator: Generator

    def check(self) -> None:
        self.generator.main(["--check"], self.path)

    def edit(self, name: str, old: str, new: str) -> None:
        path = self.path / name
        text = path.read_text()
        assert old in text
        path.write_text(text.replace(old, new, 1))

    def append(self, name: str) -> None:
        with (self.path / name).open("a") as handle:
            handle.write("(* tampered *)\n")


@pytest.fixture(params=GENERATORS, ids=IDS)
def tree(
    request: pytest.FixtureRequest,
    pristine: Callable[[Generator], Path],
    tmp_path: Path,
) -> Tree:
    shutil.copytree(pristine(request.param), tmp_path / "tree")
    return Tree(tmp_path / "tree", request.param)


@pytest.mark.parametrize("generator", GENERATORS, ids=IDS)
def test_check_passes_on_the_repository(generator: Generator, tmp_path: Path) -> None:
    script = REPOSITORY / f"scripts/generate/generate_{generator.name}.py"
    result = subprocess.run(
        [sys.executable, str(script), "--check"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "" and result.stderr == ""


def test_check_reports_a_changed_generated_file(tree: Tree) -> None:
    name = tree.generator.writes[0]
    tree.append(name)
    with pytest.raises(SystemExit, match=f"generated file differs: {name}"):
        tree.check()


def test_check_reports_a_missing_generated_file(
    pristine: Callable[[Generator], Path], tmp_path: Path
) -> None:
    shutil.copytree(pristine(FIELDS), tmp_path / "tree")
    (tmp_path / "tree" / FIELDS.writes[0]).unlink()
    with pytest.raises(SystemExit, match=f"generated file differs: {FIELDS.writes[0]}"):
        FIELDS.main(["--check"], tmp_path / "tree")


def test_check_reports_a_changed_input(tree: Tree) -> None:
    tree.edit(tree.generator.changed, tree.generator.old, tree.generator.new)
    with pytest.raises(SystemExit, match="generated file differs"):
        tree.check()


def test_write_restores_the_generated_files(tree: Tree) -> None:
    name = next(
        name for name in tree.generator.writes if name not in tree.generator.reads
    )
    tree.append(name)
    tree.generator.main([], tree.path)
    for written in tree.generator.writes:
        assert (tree.path / written).read_text() == (REPOSITORY / written).read_text()


@pytest.mark.parametrize("generator", WITH_RELEASES, ids=lambda g: g.name)
def test_catalog_must_cover_the_supported_releases(
    generator: Generator, pristine: Callable[[Generator], Path], tmp_path: Path
) -> None:
    shutil.copytree(pristine(generator), tmp_path / "tree")
    releases_file = tmp_path / "tree/catalog/releases.json"
    releases = json.loads(releases_file.read_text())
    releases["releases"].remove("3.8")
    releases_file.write_text(json.dumps(releases))
    with pytest.raises(AssertionError, match="differs from supported releases"):
        generator.main(["--check"], tmp_path / "tree")
