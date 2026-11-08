"""Check that conformance evidence cannot silently drop cases or reuse changed artifacts."""

import copy
import json
from pathlib import Path
import tempfile
import unittest

import prepare
from run import validate_fixture, validate_results


class EvidenceTest(unittest.TestCase):
    def test_fixture_identity(self):
        fixture = json.loads((prepare.HERE / "cases.json").read_text())
        self.assertEqual(len(validate_fixture(fixture)), len(fixture["cases"]))
        fixture["cases"].append(fixture["cases"][0])
        with self.assertRaisesRegex(ValueError, "unique names"):
            validate_fixture(fixture)
        fixture["java_revision"] = "different"
        with self.assertRaisesRegex(ValueError, "revision differs"):
            validate_fixture(fixture)

    def test_peer_must_return_each_case_once(self):
        result = {"name": "case", "matches": ["%1"], "encoded": {"node": "and"}}
        expected = {"case": ["%1"]}
        validate_results([result], expected)
        for results in ([], [result, result], [dict(result, name="other")]):
            with self.subTest(results=results), self.assertRaisesRegex(ValueError, "cases"):
                validate_results(results, expected)
        with self.assertRaisesRegex(ValueError, "expected"):
            validate_results([dict(result, matches=[])], expected)

    def test_prepared_cache_identity(self):
        with tempfile.TemporaryDirectory(prefix="libtmux-conformance-test-") as work:
            directory = Path(work)
            for name in ("jars/library.jar", "classes/io/github/libtmux/FilterPeer.class"):
                path = directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture")
            manifest = {"schema": prepare.SCHEMA, "revision": prepare.REVISION,
                        "inputs": prepare.build_inputs(), "toolchain": {"test": True},
                        "artifacts": prepare.artifact_hashes(directory)}
            prepare.write_json(directory / "manifest.json", manifest)
            prepare.verify_setup(directory, {"test": True})
            for key in ("revision", "inputs", "toolchain", "artifacts"):
                changed = copy.deepcopy(manifest)
                changed[key] = None
                prepare.write_json(directory / "manifest.json", changed)
                with self.subTest(key=key), self.assertRaises(RuntimeError):
                    prepare.verify_setup(directory, {"test": True})
            prepare.write_json(directory / "manifest.json", manifest)
            (directory / "jars/library.jar").write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "digests differ"):
                prepare.verify_setup(directory, {"test": True})


if __name__ == "__main__":
    unittest.main()
