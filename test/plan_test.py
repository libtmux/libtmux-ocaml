"""Outer: compare source filtering to local evaluation on an owned stable graph."""

import json
from pathlib import Path
import subprocess
import sys

from support.tmux_fixture import TmuxFixture


root = Path(__file__).resolve().parents[1]
for binary in sys.argv[1:]:
    with TmuxFixture(binary) as fixture:
        fixture.command("split-window", "-d", "-h", "-t", "fixture:0", "exec cat")
        fixture.track_panes()
        rows = fixture.command("list-panes", "-a", "-F", "#{pane_id}:#{pane_active}:#{pane_dead}").stdout.decode().splitlines()
        results = json.loads(subprocess.check_output([str(root / "_build/default/test/plan_peer.exe"), *rows]))
        for case in results:
            actual = fixture.command("list-panes", "-a", "-f", case["source"], "-F", "#{pane_id}").stdout.decode().splitlines()
            assert actual == case["matches"], (binary, case, actual)
        after = fixture.command("list-panes", "-a", "-F", "#{pane_id}:#{pane_active}:#{pane_dead}").stdout.decode().splitlines()
        assert rows == after, "fixture flags changed during evaluation"
    print(f"PASS {Path(binary).parent.name}: {len(results)} exact plans match captured evaluation")
