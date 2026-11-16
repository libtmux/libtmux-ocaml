"""Tests for the toolchain pin check."""

from pathlib import Path

import check_toolchain
import pytest

MANIFEST = """\
depends: [
  "ocaml" {= "5.5.2"}
  "dune" {= "3.24.2"}
  "ocamlfind" {with-test}
]
"""


def fake_run(versions: dict[str, str]) -> check_toolchain.Run:
    def run(command: list[str]) -> str:
        return versions[
            command[-2] if command[:3] == ["opam", "exec", "--"] else "opam"
        ]

    return run


def write_pins(
    root: Path, manifest: str = MANIFEST, tools: str = "opam 2.6.1\n"
) -> None:
    (root / "libtmux.opam").write_text(manifest)
    (root / ".tool-versions").write_text(tools)


def test_repository_pins_are_exact() -> None:
    pins = check_toolchain.pinned_versions()
    assert set(pins) == {"ocaml", "dune", "opam"}


def test_pins_come_from_the_manifest_and_tool_versions(tmp_path: Path) -> None:
    write_pins(tmp_path)
    assert check_toolchain.pinned_versions(tmp_path) == {
        "ocaml": "5.5.2",
        "dune": "3.24.2",
        "opam": "2.6.1",
    }


@pytest.mark.parametrize(
    ("manifest", "tools"),
    [
        ('"ocaml" {>= "5.5.2"}\n"dune" {= "3.24.2"}\n', "opam 2.6.1\n"),
        (MANIFEST, "python 3.14\n"),
    ],
)
def test_a_missing_or_loose_pin_is_an_error(
    tmp_path: Path, manifest: str, tools: str
) -> None:
    write_pins(tmp_path, manifest, tools)
    with pytest.raises(ValueError, match="pin"):
        check_toolchain.pinned_versions(tmp_path)


def test_each_tool_that_differs_is_named() -> None:
    pinned = {"ocaml": "5.5.2", "dune": "3.24.2", "opam": "2.6.1"}
    installed = {"ocaml": "5.5.2", "dune": "3.24.1", "opam": "2.5.0"}
    assert check_toolchain.mismatches(pinned, installed) == [
        "dune: pinned 3.24.2, installed 3.24.1",
        "opam: pinned 2.6.1, installed 2.5.0",
    ]


def test_main_passes_when_every_version_matches(tmp_path: Path) -> None:
    write_pins(tmp_path)
    versions = {"ocamlc": "5.5.2", "dune": "3.24.2", "opam": "2.6.1"}
    assert check_toolchain.main([], tmp_path, fake_run(versions)) == 0


def test_main_fails_and_reports_a_wrong_version(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    write_pins(tmp_path)
    versions = {"ocamlc": "5.4.0", "dune": "3.24.2", "opam": "2.6.1"}
    assert check_toolchain.main([], tmp_path, fake_run(versions)) == 1
    assert "ocaml: pinned 5.5.2, installed 5.4.0" in capsys.readouterr().err
