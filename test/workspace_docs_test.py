"""Outer: execute the workspace guide through real opam and an installed CLI."""
import ctypes
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0):
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
document = (root / "docs/workspaces.md").read_text()
walkthrough = document.split("<!-- workspace-walkthrough:begin -->", 1)[1].split(
    "<!-- workspace-walkthrough:end -->", 1)[0]
commands = re.findall(r"```console\n\$ (.*?)\n```", walkthrough, re.DOTALL)
assert commands and commands[-1].startswith("rmdir ")

with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-workspace-docs-") as temporary:
    temporary = Path(temporary)
    prefix = temporary / "installed"
    subprocess.run(["dune", "install", "--prefix", str(prefix), "libtmux-workspace-cli"],
                   cwd=root, check=True, capture_output=True)
    for binary in sys.argv[1:]:
        actual = str(Path(binary).resolve(strict=True))
        bindir = temporary / Path(binary).parent.name
        bindir.mkdir()
        wrapper = bindir / "tmux"
        wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(actual)} \"$@\"\n")
        wrapper.chmod(0o700)
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"TMUX", "TMUX_PANE"}}
        environment["PATH"] = os.pathsep.join([str(bindir), str(prefix / "bin"), environment["PATH"]])
        child_file = Path(f"/proc/self/task/{os.getpid()}/children")
        previous_children = set(map(int, child_file.read_text().split()))
        resolved = subprocess.check_output(["opam", "exec", "--", "sh", "-c",
                                            "command -v tmux-workspace"],
                                           cwd=root, env=environment, text=True).strip()
        assert Path(resolved).is_file() and "_build" not in Path(resolved).parts
        script = ["set -eu"]
        first_cleanup = True
        for command in commands:
            if "kill-session" in command and first_cleanup:
                script += ["printf 'BEFORE_CLEANUP\\n'", "read answer"]
                first_cleanup = False
            script.append(command)
            if command.startswith("export LIBTMUX_WORKSPACE_DIR="):
                script += ["printf 'DIRECTORY %s\\n' \"$LIBTMUX_WORKSPACE_DIR\"", "read answer"]
            if "new-session" in command:
                script += ["printf 'SERVER_READY\\n'", "read answer"]
        process = subprocess.Popen(["/bin/sh", "-c", "\n".join(script)], cwd=root,
                                   env=environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        directory = None
        daemon = None
        descriptors = {}
        output = []

        def tmux(*args):
            return subprocess.check_output([actual, "-N", "-S", str(directory / "server"), *args],
                                           env=environment, timeout=1)

        def remember():
            global daemon
            daemon = int(tmux("display-message", "-p", "#{pid}"))
            assert daemon in set(map(int, child_file.read_text().split())) - previous_children
            for pid in [daemon, *map(int, tmux("list-panes", "-a", "-F", "#{pane_pid}").splitlines())]:
                if pid not in descriptors:
                    descriptors[pid] = os.pidfd_open(pid)

        try:
            with selectors.DefaultSelector() as ready:
                ready.register(process.stdout, selectors.EVENT_READ)
                while True:
                    assert ready.select(1), "workspace guide stopped progressing"
                    line = process.stdout.readline()
                    if not line:
                        break
                    output.append(line)
                    if line.startswith(b"DIRECTORY "):
                        directory = Path(os.fsdecode(line[len(b"DIRECTORY "):].strip()))
                        assert directory.name.startswith("libtmux-ocaml-workspace.")
                        assert directory.stat().st_mode & 0o077 == 0
                        process.stdin.write(b"continue\n")
                    elif line in {b"SERVER_READY\n", b"BEFORE_CLEANUP\n"}:
                        remember()
                        if line == b"BEFORE_CLEANUP\n":
                            receipt = json.loads((directory / "receipt.json").read_text())
                            assert receipt["schema"] == "libtmux.workspace-receipt/1"
                            assert receipt["status"] == "succeeded"
                            assert not any(receipt[key] for key in ["failed", "uncertain", "skipped"])
                            assert tmux("list-clients") == b""
                            assert tmux("list-panes", "-s", "-t", "=ocaml-project", "-F", "#{pane_current_path}").splitlines() == [os.fsencode(directory)] * 3
                        process.stdin.write(b"continue\n")
            _, error = process.communicate(timeout=1)
            assert process.returncode == 0 and not error, (process.returncode, output, error)
            assert b'Valid workspace "ocaml-project": 2 windows, 3 panes\n' in b"".join(output)
            assert b"editor:2\nlogs:1\n" in b"".join(output)
            assert not directory.exists(), "guide left its private directory"
            for descriptor in descriptors.values():
                with selectors.DefaultSelector() as ready:
                    ready.register(descriptor, selectors.EVENT_READ)
                    assert ready.select(1), "guide left an owned process alive"
            os.waitpid(daemon, 0)
            daemon = None
            print(f"PASS {Path(binary).parent.name}: literal workspace guide, installed CLI, receipt and owned teardown")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=1)
            if daemon is None and directory is not None and (directory / "server").exists():
                remember()
            if daemon is not None:
                try:
                    signal.pidfd_send_signal(descriptors[daemon], signal.SIGTERM)
                except ProcessLookupError:
                    pass
                os.waitpid(daemon, 0)
            for descriptor in descriptors.values():
                os.close(descriptor)
            for stream in [process.stdin, process.stdout, process.stderr]:
                stream.close()
            if directory is not None and directory.exists():
                shutil.rmtree(directory)
