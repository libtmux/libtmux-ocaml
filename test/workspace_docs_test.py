"""Outer: run the workspace guide's commands through opam and an installed CLI."""

import ctypes
import os
import re
import selectors
import shlex
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

PR_SET_CHILD_SUBREAPER = 36

root = Path(__file__).resolve().parents[1]
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0):
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
child_file = Path(f"/proc/self/task/{os.getpid()}/children")

document = (root / "docs/workspaces.md").read_text()
commands = [
    shlex.split(block[2:].strip())
    for block in re.findall(r"```console\n(.*?)```", document, re.DOTALL)
    if block.startswith("$ ")
]
assert not any("mktemp" in command for command in commands)
check = next(c for c in commands if "tmux-workspace" in c)
apply = next(c for c in commands if any("workspace_apply.exe" in a for a in c))
assert apply[-1] == "tmux"

with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-workspace-docs-") as temporary:
    temporary = Path(temporary)
    prefix = temporary / "installed"
    subprocess.run(
        ["dune", "install", "--prefix", str(prefix), "libtmux-workspace-cli"],
        cwd=root,
        check=True,
        capture_output=True,
    )
    runtime = temporary / "runtime"
    runtime.mkdir(mode=0o700)
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in {"TMUX", "TMUX_PANE"}
    }
    environment["PATH"] = os.pathsep.join([str(prefix / "bin"), environment["PATH"]])
    environment["TMPDIR"] = str(runtime)
    resolved = subprocess.check_output(
        ["opam", "exec", "--", "sh", "-c", "command -v tmux-workspace"],
        cwd=root,
        env=environment,
        text=True,
    ).strip()
    assert Path(resolved).is_file() and "_build" not in Path(resolved).parts
    result = subprocess.run(
        check, cwd=root, env=environment, capture_output=True, timeout=5, check=True
    )
    assert result.stdout == b'Valid workspace "ocaml-project": 2 windows, 3 panes\n', (
        result
    )
    assert not result.stderr, result
    for binary in sys.argv[1:]:
        actual = str(Path(binary).resolve(strict=True))
        previous = set(map(int, child_file.read_text().split()))
        result = subprocess.run(
            [*apply[:-1], actual],
            cwd=root,
            env=dict(environment, TMUX="/unrelated/server,99999,0", TMUX_PANE="%99999"),
            capture_output=True,
            timeout=5,
            check=False,
        )
        assert result.returncode == 0 and not result.stderr, result
        assert result.stdout == (
            b'Valid workspace "ocaml-project": 2 windows, 3 panes\n'
            b"Plan: 6 actions\nReceipt: succeeded\neditor:2\nlogs:1\n"
        ), result.stdout
        assert not list(runtime.iterdir()), "the guide program left its directory"
        for pid in set(map(int, child_file.read_text().split())) - previous:
            descriptor = os.pidfd_open(pid)
            try:
                with selectors.DefaultSelector() as exited:
                    exited.register(descriptor, selectors.EVENT_READ)
                    if not exited.select(1):
                        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                        raise AssertionError("the guide program left a process alive")
                os.waitpid(pid, 0)
            finally:
                os.close(descriptor)
        print(
            f"PASS {Path(binary).parent.name}: workspace guide check, apply and owned teardown"
        )
