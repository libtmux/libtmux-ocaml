"""Outer: native cache hits validate private daemons; corruption rebuilds safely."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
from unittest.mock import patch

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("tmux_build", root / ".github/scripts/tmux_build.py")
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
binary = Path(sys.argv[1]).resolve(strict=True)
version = cache._output([str(binary), "-V"]).removeprefix("tmux ")
identity = {"version": version, "source": cache._RELEASES[version]}
with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-cache-") as temporary:
    prefix = Path(temporary) / "installed"
    def build(directory, _):
        (directory / "bin").mkdir(parents=True)
        shutil.copy2(binary, directory / "bin/tmux")
    with patch.object(cache, "_build", build) as compile_:
        assert cache._prepare(prefix, identity)
        original = (prefix / "bin/tmux").read_bytes()
        with patch.object(cache, "_build", side_effect=AssertionError("valid cache rebuilt")):
            assert not cache._prepare(prefix, identity)
        (prefix / "bin/tmux").write_bytes(b"corrupt")
        assert cache._prepare(prefix, identity)
        assert (prefix / "bin/tmux").read_bytes() == original
        unrelated = Path(temporary) / "unrelated"
        unrelated.mkdir()
        (unrelated / "keep").write_text("preserved")
        shutil.rmtree(prefix)
        prefix.symlink_to(unrelated, target_is_directory=True)
        assert cache._prepare(prefix, identity)
        assert (unrelated / "keep").read_text() == "preserved"
        changed = dict(identity, source="different-source")
        assert cache._cache_key(identity) != cache._cache_key(changed)
        record = json.loads((prefix / "build.json").read_text())
        assert record["sha256"] == hashlib.sha256(original).hexdigest()
        with patch.object(cache, "_build", side_effect=RuntimeError("build failed")):
            try:
                cache._prepare(prefix, changed)
            except RuntimeError:
                pass
            else:
                raise AssertionError("failed build accepted")
        assert not (prefix / "build.json").exists()
print("PASS cache hit, corruption recovery, source identity, symlink and failed-build safety")
