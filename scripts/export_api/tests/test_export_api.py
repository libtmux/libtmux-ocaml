"""Tests for the public interface exporter.

The script's own checks run against temporary Git repositories with a stub
exporter. The compiler-backed extraction tests run only with
LIBTMUX_API_EXPORT=1, as the Dune stanza that builds tools/api_export.exe does.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import export_api
import pytest

REPOSITORY = Path(__file__).resolve().parents[3]
EXPORTER = REPOSITORY / export_api.EXPORTER


@pytest.fixture(autouse=True)
def clean_git_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """Keep inherited GIT_* variables from redirecting the temporary repositories."""
    for name in [name for name in os.environ if name.startswith("GIT_")]:
        monkeypatch.delenv(name)


# Stub exporter: tmp repository with a fake compiler-backed exporter


def symbol(identifier: str, **fields: object) -> dict[str, Any]:
    return {
        "id": identifier,
        "apiScope": "exported",
        "source": {"file": "lib/demo.mli", "line": 1},
        "declarations": [{"source": {"file": "lib/demo.mli", "line": 1}}],
        **fields,
    }


def git(repository: Path, *arguments: str) -> str:
    return subprocess.run(
        [
            "git",
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            *arguments,
        ],
        cwd=repository,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()


class Repository:
    """A committed library tree whose exporter prints a canned artifact."""

    def __init__(self, path: Path) -> None:
        self.path = path
        for name, text in {
            "lib/demo.mli": "val run : unit -> unit\n",
            "tools/api_export.ml": "(* exporter *)\n",
            "tools/api_doc.ml": "(* docs *)\n",
            "tools/dune": "(executable (name api_export))\n",
            "scripts/export_api/export_api.py": "# script\n",
            "tools/api_modules.json": json.dumps(
                {
                    "schema": "libtmux.ocaml-public/1",
                    "modules": [
                        {
                            "module": "Demo",
                            "package": "demo",
                            "product": "core",
                            "source": "lib/demo.mli",
                        }
                    ],
                }
            ),
        }.items():
            self.write(name, text)
        git(path, "init", "-q")
        git(path, "add", "lib", "tools", "scripts")
        git(path, "commit", "-q", "-m", "library")
        self.head = git(path, "rev-parse", "HEAD")
        self.write("_build/install/default/lib/demo/demo.cmti", "annotations")
        self.install()
        self.artifact([symbol("Demo.run")])

    def write(self, name: str, text: str) -> None:
        target = self.path / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def install(self, installed: bool = True) -> None:
        entry = '  "_build/install/default/lib/demo/demo.cmti"\n' if installed else ""
        self.write("_build/default/demo.install", f"lib: [\n{entry}]\n")

    def artifact(self, symbols: list[dict[str, Any]]) -> None:
        self.write(
            "_build/default/tools/artifact.json",
            json.dumps({"compiler": "5.5.2", "schema": "stub/1", "symbols": symbols}),
        )
        stub = self.path / export_api.EXPORTER
        stub.write_text('#!/bin/sh\ncat "$(dirname "$0")/artifact.json"\n')
        stub.chmod(0o755)

    def export(self, revision: str | None = None) -> tuple[dict[str, Any], int]:
        return export_api.export(self.path, revision)


@pytest.fixture
def repository(tmp_path: Path) -> Repository:
    library = Repository(tmp_path)
    artifact, interfaces = library.export()  # the unmodified tree exports cleanly
    assert interfaces == 1 and artifact["symbols"]
    return library


def test_export_records_revision_and_provenance(repository: Repository) -> None:
    artifact, interfaces = repository.export()
    assert interfaces == 1
    assert artifact["revision"] == repository.head
    assert artifact["port"] == "ocaml"
    assert artifact["sources"] == [
        {
            "product": "core",
            "package": "demo",
            "repo": artifact["repo"],
            "revision": repository.head,
        }
    ]
    [run] = artifact["symbols"]
    assert run["source"]["revision"] == repository.head
    assert run["declarations"][0]["source"]["repo"] == artifact["repo"]
    provenance = artifact["nativeProvenance"]
    assert [item["path"] for item in provenance["files"]] == [
        "lib/demo.mli",
        "_build/install/default/lib/demo/demo.cmti",
    ]
    assert provenance["exporter"]["revision"] == repository.head
    assert [item["path"] for item in provenance["exporter"]["files"]] == (
        export_api.TOOL_FILES
    )


def test_uncommitted_exporter_file_clears_the_exporter_revision(
    repository: Repository,
) -> None:
    repository.write("tools/dune", "(executable (name changed))\n")
    provenance = repository.export()[0]["nativeProvenance"]["exporter"]
    assert provenance["revision"] is None
    assert provenance["baseRevision"] == repository.head


def test_main_writes_the_artifact(
    repository: Repository,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    output = repository.path / "out/ocaml.json"
    monkeypatch.setattr(export_api, "ROOT", repository.path)
    monkeypatch.setattr(sys, "argv", ["export_api.py", "--output", str(output)])
    export_api.main()
    assert json.loads(output.read_text())["revision"] == repository.head
    assert capsys.readouterr().out == "Exported 1 public symbols from 1 interfaces\n"


def test_rejects_source_that_differs_from_the_library_revision(
    repository: Repository,
) -> None:
    repository.write("lib/demo.mli", "val run : unit -> unit\nval extra : int\n")
    with pytest.raises(
        AssertionError,
        match=re.escape("public source differs from library revision: lib/demo.mli"),
    ):
        repository.export()


def test_rejects_interface_missing_from_the_dune_installation(
    repository: Repository,
) -> None:
    repository.install(installed=False)
    with pytest.raises(AssertionError, match="not in Dune installation"):
        repository.export()


@pytest.mark.parametrize(
    "leaked",
    [
        symbol("Demo__Private.hidden"),
        symbol("Demo.hidden", apiScope="internal"),
    ],
    ids=["private-module-id", "non-exported-scope"],
)
def test_rejects_private_module_leak(
    repository: Repository, leaked: dict[str, Any]
) -> None:
    repository.artifact([symbol("Demo.run"), leaked])
    with pytest.raises(AssertionError, match="private module leaked"):
        repository.export()


def test_rejects_duplicate_symbol_identities(repository: Repository) -> None:
    repository.artifact([symbol("Demo.run"), symbol("Demo.run")])
    with pytest.raises(AssertionError, match="duplicate public symbol identities"):
        repository.export()


# Real exporter: compiler-backed extraction, enabled with LIBTMUX_API_EXPORT=1

SOURCE = """(** Public fixture with [inline code]. *)
module type ID = sig
  type t
  val of_string : string -> (t, string) result
end
module Nested : sig
  type t
  type alias = t
  (** Perform the operation with {!t}.

      Preserve the result. {!type-state}, {!val-state},
      {{!type-state}the state type} and [state].
      {{:https://ocaml.org/manual/5.5/typedecl.html}Type guide}. *)
  val run : ?limit:int -> name:string -> t -> (alias, string) result
  type state = Ready | Failed of { message : string }
  val state : unit -> state
end
module Id : ID
module Alias = Nested
module Cleanup : sig
  type t = Cleanup.t
end
"""


class Project:
    """A compiled fixture library the real exporter reads."""

    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self.manifest: dict[str, Any] = {
            "modules": [
                {
                    "module": "Public",
                    "package": "fixture",
                    "product": "core",
                    "submodules": {"Nested": "workspace"},
                    "source": "public.mli",
                    "cmti": "public.cmti",
                }
            ]
        }
        (directory / "public.mli").write_text(SOURCE)
        (directory / "private.mli").write_text("val hidden : unit -> unit\n")
        (directory / "implementation.mli").write_text("type t\n")
        (directory / "public__.ml").write_text("module Cleanup = Implementation\n")
        for name in ("implementation.mli", "public__.ml", "private.mli"):
            self.ocamlc("-c", name)
        self.compile_public()
        self.write_manifest()

    def ocamlc(self, *arguments: str) -> None:
        subprocess.run(
            ["ocamlc", "-bin-annot", *arguments],
            cwd=self.directory,
            check=True,
        )

    def compile_public(self) -> None:
        self.ocamlc("-open", "Public__", "-c", "public.mli")

    def write_manifest(self) -> None:
        (self.directory / "manifest.json").write_text(json.dumps(self.manifest))

    def write_source(self, text: str) -> None:
        (self.directory / "public.mli").write_text(text)

    def extract(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(EXPORTER), str(self.directory), str(self.directory / "manifest.json")],
            cwd=REPOSITORY,
            capture_output=True,
            text=True,
            check=False,
        )

    def symbols(self) -> dict[str, dict[str, Any]]:
        result = self.extract()
        assert result.returncode == 0, result.stderr
        model = json.loads(result.stdout)
        symbols = {item["id"]: item for item in model["symbols"]}
        assert len(symbols) == len(model["symbols"]), "colliding public identities"
        return symbols


@pytest.fixture
def project(tmp_path: Path) -> Iterator[Project]:
    if os.environ.get("LIBTMUX_API_EXPORT") != "1":
        pytest.skip("tools/api_export.exe is built only with LIBTMUX_API_EXPORT=1")
    assert EXPORTER.is_file(), (
        "build the exporter: LIBTMUX_API_EXPORT=1 dune build tools/api_export.exe"
    )
    assert shutil.which("ocamlc"), "ocamlc is not on PATH"
    yield Project(tmp_path)


def test_extracts_opaque_types_aliases_and_modules(project: Project) -> None:
    symbols = project.symbols()
    assert "Private.hidden" not in symbols
    opaque = symbols["Public.Nested.t"]
    assert opaque["kind"] == "typealias" and opaque["modifiers"] == ["opaque"]
    assert symbols["Public.Nested.alias"]["type"] == "t"
    cleanup = symbols["Public.Cleanup.t"]
    assert cleanup["type"] == "Cleanup.t", cleanup
    assert cleanup["signatures"][0]["raw"] == "type t = Cleanup.t", cleanup
    assert symbols["Public.Alias"]["exportedFrom"] == "Public.Nested"
    assert "Public.Id.of_string" in symbols, "public module type was not expanded"


def test_extracts_labelled_signatures_and_docs(project: Project) -> None:
    symbols = project.symbols()
    run = symbols["Public.Nested.run"]
    signature = run["signatures"][0]
    assert [param["name"] for param in signature["params"]] == ["limit", "name", "arg1"]
    assert (
        signature["params"][0]["optional"] and signature["params"][0]["type"] == "int"
    )
    assert signature["params"][1]["keywordOnly"]
    assert all("default" not in param for param in signature["params"])
    assert signature["returns"] == "(alias, string) result"
    assert signature["raw"].startswith("val run : ?limit:int -> name:string ->")
    assert run["doc"]["summary"] == "Perform the operation with {!t}."
    body = run["doc"]["body"]
    assert "Preserve the result." in body
    assert "{!type-state}" in body
    assert "{!val-state}" in body
    assert "{{!type-state}the state type}" in body
    assert "`state`" in body
    assert "[Type guide](https://ocaml.org/manual/5.5/typedecl.html)" in body
    assert "inline code" in symbols["Public"]["doc"]["summary"]


def test_extracts_sources_products_and_variants(project: Project) -> None:
    symbols = project.symbols()
    run = symbols["Public.Nested.run"]
    assert run["source"] == {"file": "public.mli", "line": 14}
    assert symbols["Public"]["product"] == "core"
    assert run["product"] == "workspace"
    assert run["declarations"][0]["text"].strip() == SOURCE.splitlines()[13].strip()
    assert symbols["Public.Nested.state:type.Failed"]["variant"] == "struct"
    assert "Public.Nested.state:type.Failed.message" in symbols
    assert symbols["Public.Nested.state"]["kind"] == "function"
    assert symbols["Public.Nested.state:type"]["qualifiedName"] == "Public.Nested.state"
    assert (
        symbols["Public.Nested.state:type.Failed"]["qualifiedName"]
        == "Public.Nested.Failed"
    )


def test_exporter_rejects_stale_source(project: Project) -> None:
    project.write_source(SOURCE + "\nval stale : int\n")
    stale = project.extract()
    assert stale.returncode != 0 and "source digest" in stale.stderr


def test_exporter_rejects_cmi_only_input(project: Project) -> None:
    project.manifest["modules"][0]["cmti"] = "public.cmi"
    project.write_manifest()
    fallback = project.extract()
    assert fallback.returncode != 0 and ".cmti" in fallback.stderr


def test_exporter_rejects_alias_to_a_private_module(project: Project) -> None:
    project.write_source(
        SOURCE.replace("module Alias = Nested", "module Alias = Private")
    )
    project.compile_public()
    private = project.extract()
    assert (
        private.returncode != 0
        and "outside the public module manifest" in private.stderr
    )
