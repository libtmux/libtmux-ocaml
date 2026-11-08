"""Outer: build the OCaml peer, compare both evaluators and exchange query JSON."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from prepare import (DEFAULT_SETUP, HERE, ROOT, REVISION, digest, run_logged,
                     toolchain, verify_setup, write_json)

sys.path.insert(0, str(ROOT / "tools"))
from check import source_snapshot


def validate_fixture(fixture):
    if fixture.get("java_revision") != REVISION:
        raise ValueError("fixture Java revision differs from the prepared peer")
    cases = fixture["cases"]
    names = [case["name"] for case in cases]
    if not names or len(names) != len(set(names)):
        raise ValueError("fixture must contain cases with unique names")
    return {case["name"]: case["matches"] for case in cases}


def validate_results(results, expected):
    names = [item["name"] for item in results]
    if len(names) != len(set(names)) or set(names) != set(expected):
        raise ValueError("peer omitted, duplicated or added cases")
    for item in results:
        if item["matches"] != expected[item["name"]]:
            raise ValueError(f"{item['name']}: expected {expected[item['name']]}, got {item['matches']}")
        if not isinstance(item.get("encoded"), dict):
            raise ValueError(f"{item['name']}: peer did not encode a query")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--setup", type=Path, default=DEFAULT_SETUP)
    parser.add_argument("--output", type=Path, help="new directory for retained qualification results")
    parser.add_argument("--java-home", type=Path, help="the JDK used to prepare the Java peer")
    parser.add_argument("--fixture", type=Path, default=HERE / "cases.json")
    args = parser.parse_args()
    if args.output:
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        results = ROOT / "scratch/conformance-results"
        results.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix="run-", dir=results))
    record = {"status": "FAIL", "steps": []}
    started = time.monotonic()
    try:
        fixture_bytes = args.fixture.read_bytes()
        fixture_path = output / "fixture.json"
        fixture_path.write_bytes(fixture_bytes)
        record["fixture_sha256"] = digest(fixture_path)
        fixture = json.loads(fixture_bytes)
        expected = validate_fixture(fixture)
        commands, identity, env = toolchain(args.java_home)
        for name in ("DUNE_WORKSPACE", "DUNE_SOURCEROOT"):
            env.pop(name, None)
        manifest, jars = verify_setup(args.setup.resolve(), identity)
        write_json(output / "java-manifest.json", manifest)
        record["java_manifest_sha256"] = digest(output / "java-manifest.json")
        source, archive, archive_digest = source_snapshot(ROOT, output / "source")
        record["source"] = {"sha256": source, "archive": str(archive.relative_to(output)),
                            "archive_sha256": archive_digest,
                            "head": subprocess.check_output(["git", "rev-parse", "HEAD"],
                                                            cwd=ROOT, text=True).strip()}
        steps = record["steps"]
        for name, command in (("ocaml-version", ["ocamlc", "-version"]),
                              ("dune-version", ["dune", "--version"]),
                              ("ocaml-build", ["dune", "build", "--root", str(ROOT),
                                                "--build-dir", str(ROOT / "_build"),
                                                "test/conformance/filter_peer.exe"])):
            run_logged(command, output, name, steps, env=env)
        peer = ROOT / "_build/default/test/conformance/filter_peer.exe"
        record["ocaml_peer_sha256"] = digest(peer)
        java = [commands["java"], "-cp", os.pathsep.join(map(str, [args.setup.resolve() / "classes", *jars])),
                "io.github.libtmux.FilterPeer"]
        ocaml = [str(peer)]

        def evaluate(label, command, path):
            text = run_logged([*command, str(path)], output, label, steps, env=env, timeout=60)
            results = json.loads(text)
            validate_results(results, expected)
            return results

        java_results = evaluate("java", java, fixture_path)
        ocaml_results = evaluate("ocaml", ocaml, fixture_path)
        for label, results, decoder in (("java-to-ocaml", java_results, ocaml),
                                         ("ocaml-to-java", ocaml_results, java)):
            exchanged = dict(fixture, cases=[{"name": item["name"], "query": item["encoded"]}
                                            for item in results])
            path = output / f"{label}.json"
            write_json(path, exchanged)
            evaluate(label, decoder, path)
        record.update(status="PASS", cases=len(expected))
    except BaseException as error:
        record["error"] = str(error)
        raise
    finally:
        record["seconds"] = round(time.monotonic() - started, 4)
        write_json(output / "result.json", record)
        print(f"{record['status']} conformance ({record['seconds']:.3f}s): {output}")


if __name__ == "__main__":
    main()
