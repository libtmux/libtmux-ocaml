"""Offline checks for release identity and retained artifact integrity."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("release.py")
PACKAGES = (
    "libtmux", "libtmux-eio", "libtmux-json", "libtmux-unix",
    "libtmux-workspace", "libtmux-workspace-cli",
)


class ReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="libtmux-ocaml-release-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "dune-project").write_text("(name libtmux)\n(version 0.0.1)\n")
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## Unreleased\n\n## 0.0.1\n\n- Initial native packages.\n"
        )
        for package in PACKAGES:
            (self.root / f"{package}.opam").write_text('opam-version: "2.0"\n')
        self.git("init", "--quiet", "--initial-branch=master")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Initial fixture")
        self.git("update-ref", "refs/remotes/origin/master", "HEAD")

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-c", "user.name=release-test", "-c", "user.email=release@example.invalid", *args],
            cwd=self.root, text=True, stderr=subprocess.STDOUT,
        ).strip()

    def run_release(self, *args, success=True):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args], cwd=self.root,
            text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_rehearsal_records_all_packages_without_creating_a_tag(self):
        metadata = json.loads(self.run_release("check").stdout)
        self.assertEqual(metadata["version"], "0.0.1")
        self.assertEqual(metadata["tag"], "v0.0.1")
        self.assertEqual(metadata["packages"], list(PACKAGES))
        self.assertIn("Initial native packages.", metadata["notes"])
        self.assertEqual(self.git("tag", "--list"), "")

    def test_rejects_a_tag_that_disagrees_with_the_package_version(self):
        result = self.run_release("check", "--tag", "v0.0.2", success=False)
        self.assertIn("version", result.stderr)

    def test_publishing_requires_an_annotated_tag_at_head_on_master(self):
        self.git("tag", "v0.0.1")
        result = self.run_release("check", "--tag", "v0.0.1", "--publish", success=False)
        self.assertIn("annotated", result.stderr)
        self.git("tag", "--delete", "v0.0.1")
        self.git("tag", "--annotate", "v0.0.1", "--message", "Release 0.0.1")
        self.run_release("check", "--tag", "v0.0.1", "--publish")
        self.git("commit", "--allow-empty", "--quiet", "-m", "Later fixture")
        result = self.run_release("check", "--tag", "v0.0.1", "--publish", success=False)
        self.assertIn("HEAD", result.stderr)
        self.git("tag", "--force", "--annotate", "v0.0.1", "--message", "Unmerged fixture")
        result = self.run_release("check", "--tag", "v0.0.1", "--publish", success=False)
        self.assertIn("master", result.stderr)

    def test_rejects_missing_release_notes_and_a_partial_package_set(self):
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## Unreleased\n")
        self.assertIn("changelog", self.run_release("check", success=False).stderr)
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## 0.0.1\n\n- Release.\n")
        (self.root / "libtmux-eio.opam").unlink()
        self.assertIn("package", self.run_release("check", success=False).stderr)

    def test_retained_files_must_match_the_source_identity_and_checksums(self):
        directory = self.root / "dist"
        directory.mkdir()
        metadata = self.run_release("check").stdout
        (directory / "release.json").write_text(metadata)
        (directory / "libtmux-v0.0.1.tbz").write_bytes(b"source archive")
        for package in PACKAGES:
            destination = directory / f"{package}.0.0.1"
            destination.mkdir()
            (destination / "opam").write_text('opam-version: "2.0"\n')
        self.run_release("seal", "--directory", str(directory))
        self.run_release("verify", "--directory", str(directory))
        (directory / "libtmux-v0.0.1.tbz").write_bytes(b"changed archive")
        self.assertIn("checksum", self.run_release("verify", "--directory", str(directory), success=False).stderr)
        (directory / "libtmux-v0.0.1.tbz").write_bytes(b"source archive")
        self.git("commit", "--allow-empty", "--quiet", "-m", "Different source")
        self.assertIn("commit", self.run_release("verify", "--directory", str(directory), success=False).stderr)


if __name__ == "__main__":
    unittest.main()
