"""Export installed public .cmti interfaces with separate source/tool provenance."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--revision", help="Library commit; public interface bytes must match")
args = parser.parse_args()


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments])


def digest(path):
    return hashlib.sha256((root / path).read_bytes()).hexdigest()


head = git("rev-parse", "HEAD").decode().strip()
revision = git("rev-parse", "--verify", (args.revision or head) + "^{commit}").decode().strip()
manifest = json.loads((root / "tools/api_modules.json").read_text())
assert manifest["schema"] == "libtmux.ocaml-public/1"
assert len({item["module"] for item in manifest["modules"]}) == len(manifest["modules"])
inputs = []
for entry in manifest["modules"]:
    source = entry["source"]
    assert git("show", f"{revision}:{source}") == (root / source).read_bytes(), \
        f"public source differs from library revision: {source}"
    cmti = f'_build/install/default/lib/{entry["package"]}/{entry["module"].lower()}.cmti'
    installation = (root / f'_build/default/{entry["package"]}.install').read_text()
    assert f'"{cmti}"' in installation, f"public interface is not in Dune installation: {cmti}"
    entry["cmti"] = cmti
    inputs.extend([{"path": source, "sha256": digest(source)},
                   {"path": cmti, "sha256": digest(cmti)}])
with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as temporary:
    json.dump(manifest, temporary)
    temporary.flush()
    native = subprocess.check_output([str(root / "_build/default/tools/api_export.exe"),
                                      str(root), temporary.name], cwd=root)
artifact = json.loads(native)
artifact["port"] = "ocaml"
artifact["repo"] = "https://github.com/libtmux/libtmux-ocaml"
artifact["revision"] = revision
artifact["extractor"] = "OCaml 5.5.2 compiler-libs .cmti + odoc-parser 3.2.2"
artifact["sources"] = [{"product": item["product"], "package": item["package"],
                         "repo": artifact["repo"], "revision": revision}
                        for item in manifest["modules"]]
tool_files = ["tools/api_export.ml", "tools/api_doc.ml", "tools/export_api.py",
              "tools/api_modules.json", "tools/dune"]
tool_hashes = [{"path": path, "sha256": digest(path)} for path in tool_files]
tool_clean = all(subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{head}:{path}"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
                 and git("show", f"{head}:{path}") == (root / path).read_bytes()
                 for path in tool_files)
artifact["nativeProvenance"] = {"files": inputs, "exporter": {
    "revision": head if tool_clean else None, "baseRevision": head, "files": tool_hashes,
    "compiler": artifact["compiler"], "schema": artifact["schema"],
    "publicManifest": "tools/api_modules.json"}}
symbols = artifact["symbols"]
ids = {symbol["id"] for symbol in symbols}
assert len(ids) == len(symbols), "duplicate public symbol identities"
for symbol in symbols:
    assert not symbol.get("parent") or symbol["parent"] in ids
    assert not symbol.get("exportedFrom") or symbol["exportedFrom"] in ids
    assert symbol["apiScope"] == "exported" and "__" not in symbol["id"], "private module leaked"
    for source in [symbol["source"], *(item["source"] for item in symbol.get("declarations", []))]:
        source.update(repo=artifact["repo"], revision=revision)
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(artifact, indent=2, ensure_ascii=False) + "\n")
print(f"Exported {len(symbols)} public symbols from {len(manifest['modules'])} interfaces")
