"""Outer: exercise public interface extraction with real compiler artifacts."""
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
exporter = root / "_build/default/tools/api_export.exe"
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-api-") as temporary:
    project = Path(temporary)
    source = '''(** Public fixture with [inline code]. *)
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
'''
    (project / "public.mli").write_text(source)
    (project / "private.mli").write_text("val hidden : unit -> unit\n")
    for name in ("public", "private"):
        subprocess.run(["ocamlc", "-bin-annot", "-c", name + ".mli"], cwd=project, check=True)
    manifest = {"modules": [{"module": "Public", "package": "fixture", "product": "core",
                              "source": "public.mli", "cmti": "public.cmti"}]}
    path = project / "manifest.json"
    path.write_text(json.dumps(manifest))

    def extract():
        return subprocess.run([str(exporter), str(project), str(path)],
                              cwd=root, capture_output=True, text=True)

    result = extract()
    assert result.returncode == 0, result.stderr
    model = json.loads(result.stdout)
    symbols = {symbol["id"]: symbol for symbol in model["symbols"]}
    assert "Private.hidden" not in symbols
    opaque = symbols["Public.Nested.t"]
    assert opaque["kind"] == "typealias" and opaque["modifiers"] == ["opaque"]
    assert symbols["Public.Nested.alias"]["type"] == "t"
    assert symbols["Public.Alias"]["exportedFrom"] == "Public.Nested"
    assert "Public.Id.of_string" in symbols, "public module type was not expanded"
    run = symbols["Public.Nested.run"]
    signature = run["signatures"][0]
    assert [param["name"] for param in signature["params"]] == ["limit", "name", "arg1"]
    assert signature["params"][0]["optional"] and signature["params"][0]["type"] == "int"
    assert signature["params"][1]["keywordOnly"]
    assert all("default" not in param for param in signature["params"])
    assert signature["returns"] == "(alias, string) result"
    assert signature["raw"].startswith("val run : ?limit:int -> name:string ->")
    assert run["doc"]["summary"] == "Perform the operation with {!t}."
    assert "Preserve the result." in run["doc"]["body"]
    assert "{!type-state}" in run["doc"]["body"]
    assert "{!val-state}" in run["doc"]["body"]
    assert "{{!type-state}the state type}" in run["doc"]["body"]
    assert "`state`" in run["doc"]["body"]
    assert "[Type guide](https://ocaml.org/manual/5.5/typedecl.html)" in run["doc"]["body"]
    assert "inline code" in symbols["Public"]["doc"]["summary"]
    assert run["source"] == {"file": "public.mli", "line": 14}
    assert run["declarations"][0]["text"].strip() == source.splitlines()[13].strip()
    assert symbols["Public.Nested.state:type.Failed"]["variant"] == "struct"
    assert "Public.Nested.state:type.Failed.message" in symbols
    assert symbols["Public.Nested.state"]["kind"] == "function"
    assert symbols["Public.Nested.state:type"]["qualifiedName"] == "Public.Nested.state"
    assert symbols["Public.Nested.state:type.Failed"]["qualifiedName"] == "Public.Nested.Failed"
    assert len(symbols) == len(model["symbols"]), "colliding public identities"
    (project / "public.mli").write_text(source + "\nval stale : int\n")
    stale = extract()
    assert stale.returncode != 0 and "source digest" in stale.stderr
    (project / "public.mli").write_text(source)
    manifest["modules"][0]["cmti"] = "public.cmi"
    path.write_text(json.dumps(manifest))
    fallback = extract()
    assert fallback.returncode != 0 and ".cmti" in fallback.stderr
    manifest["modules"][0]["cmti"] = "public.cmti"
    path.write_text(json.dumps(manifest))
    (project / "public.mli").write_text(source.replace("module Alias = Nested", "module Alias = Private"))
    subprocess.run(["ocamlc", "-bin-annot", "-c", "public.mli"], cwd=project, check=True)
    private = extract()
    assert private.returncode != 0 and "outside the public module manifest" in private.stderr
print("PASS public cmti: opaque types, aliases, labels, results, docs, sources, freshness and private exclusion")
