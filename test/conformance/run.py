"""Outer: compare both real evaluators and exchange their encoded queries."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[2]
setup = root / "scratch/java-conformance"
source = setup / "source"
pin = "e8a39689d8d60968ac978a1dd2a89c6112333896"
assert (setup / "source-revision").read_text().strip() == pin
cache = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle")) / "caches/modules-2/files-2.1"
jars = [source / "libtmux/build/libs/libtmux-0.1.2-SNAPSHOT.jar",
        source / "libtmux-jackson/build/libs/libtmux-jackson-0.1.2-SNAPSHOT.jar"]
for artifact, version in (("jackson-databind", "2.21.5"), ("jackson-core", "2.21.5"), ("jackson-annotations", "2.21")):
    matches = list((cache / "com.fasterxml.jackson.core" / artifact / version).glob("*/*.jar"))
    assert len(matches) == 1, artifact
    jars.extend(matches)
classpath = os.pathsep.join(map(str, jars))
classes = setup / "classes"
classes.mkdir(exist_ok=True)
subprocess.run(["javac", "-cp", classpath, "-d", str(classes), str(root / "test/conformance/FilterPeer.java")], check=True)
fixture = json.loads((root / "test/conformance/cases.json").read_text())
java = ["java", "-cp", str(classes) + os.pathsep + classpath, "io.github.libtmux.FilterPeer"]
ocaml = [str(root / "_build/default/test/conformance/filter_peer.exe")]


def evaluate(command, input_file):
    return json.loads(subprocess.check_output([*command, str(input_file)], text=True))


with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-conformance-") as directory:
    input_file = Path(directory) / "fixture.json"
    input_file.write_text(json.dumps(fixture))
    java_results = evaluate(java, input_file)
    ocaml_results = evaluate(ocaml, input_file)
    expected = {case["name"]: case["matches"] for case in fixture["cases"]}
    for label, results in (("Java", java_results), ("OCaml", ocaml_results)):
        assert {item["name"]: item["matches"] for item in results} == expected, label
    for encoder, decoder in ((java_results, ocaml), (ocaml_results, java)):
        exchanged = dict(fixture, cases=[dict(name=item["name"], query=item["encoded"]) for item in encoder])
        input_file.write_text(json.dumps(exchanged))
        assert {item["name"]: item["matches"] for item in evaluate(decoder, input_file)} == expected
print(f"PASS Java/OCaml scalar conformance: {len(expected)} cases, both codec directions")
print(json.dumps(dict(java_revision=pin, jars=[dict(name=jar.name, sha256=hashlib.sha256(jar.read_bytes()).hexdigest()) for jar in jars])))
