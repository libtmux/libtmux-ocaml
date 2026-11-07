"""Execute the README's literal demo commands using installed example programs."""
import ctypes
import os
from pathlib import Path
import re
import selectors
import shlex
import shutil
import signal
import subprocess


def prepare(root, temporary, environment):
    project = temporary / "readme-walkthrough"
    project.mkdir()
    (project / "dune-project").write_text("(lang dune 3.24)\n")
    examples = project / "examples"
    examples.mkdir()
    for source in (root / "examples").iterdir():
        if source.name == "dune" or source.suffix == ".ml":
            shutil.copyfile(source, examples / source.name)
    subprocess.run(["dune", "build", "--root", str(project)], cwd=project,
                   env=environment, check=True, capture_output=True)
    library = subprocess.check_output(["opam", "exec", "--", "ocamlfind", "query", "libtmux"],
                                      cwd=project, env=environment, text=True).strip()
    if Path(library) != Path(environment["OCAMLPATH"]) / "libtmux":
        raise RuntimeError("README commands did not use the independent installation")
    return project


def run(root, project, binary, environment):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0):
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    commands = []
    active = False
    for block in re.findall(r"```console\n(.*?)```", (root / "README.md").read_text(), re.DOTALL):
        if block.startswith('$ export LIBTMUX_DEMO_DIR='):
            active = True
        if active:
            if not block.startswith("$ ") or "\n$ " in block:
                raise ValueError("README blocks must contain one command")
            commands.append(block[2:].rstrip())
        if active and block.startswith('$ rmdir "$LIBTMUX_DEMO_DIR"'):
            break
    if not commands or not commands[-1].startswith("rmdir"):
        raise ValueError("README demo has no complete setup/cleanup route")
    bindir = project / "bin"
    bindir.mkdir(exist_ok=True)
    wrapper = bindir / "tmux"
    actual = str(Path(binary).resolve(strict=True))
    wrapper.write_text(f"#!/bin/sh\nexec {shlex.quote(actual)} \"$@\"\n")
    wrapper.chmod(0o700)
    script = ["set -eu"]
    cleanup_inserted = False
    for command in commands:
        if "kill-session" in command and not cleanup_inserted:
            script += ["printf 'BEFORE_CLEANUP\\n'", "read answer"]
            cleanup_inserted = True
        script.append(command)
        if command.startswith("export LIBTMUX_DEMO_DIR="):
            script += ["printf 'DIRECTORY %s\\n' \"$LIBTMUX_DEMO_DIR\"", "read answer"]
        if "new-session" in command:
            script += ["printf 'SERVER_READY\\n'", "read answer"]
    child_environment = {key:value for key,value in environment.items() if key not in {"TMUX", "TMUX_PANE"}}
    child_environment["PATH"] = str(bindir) + os.pathsep + environment["PATH"]
    script_path = project / "walkthrough.sh"
    script_path.write_text("\n".join(script) + "\n")
    process = subprocess.Popen(["/bin/sh", str(script_path)], cwd=project, env=child_environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, bufsize=0)
    directory = None
    daemon = None
    pidfds = {}
    output = []

    def command(*arguments):
        return subprocess.run([actual, "-N", "-S", str(directory / "server"), *arguments],
                              env=child_environment, check=True, capture_output=True, timeout=1).stdout

    def remember():
        nonlocal daemon
        daemon = int(command("display-message", "-p", "#{pid}"))
        for pid in [daemon, *map(int, command("list-panes", "-a", "-F", "#{pane_pid}").splitlines())]:
            if pid not in pidfds:
                pidfds[pid] = os.pidfd_open(pid)

    try:
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            while True:
                if not ready.select(1):
                    raise TimeoutError("README walkthrough stopped progressing")
                line = process.stdout.readline()
                if not line:
                    break
                output.append(line)
                if line.startswith(b"DIRECTORY "):
                    directory = Path(os.fsdecode(line[len(b"DIRECTORY "):].strip()))
                    if not directory.name.startswith("libtmux-ocaml-demo.") or directory.stat().st_mode & 0o077:
                        raise RuntimeError("demo did not create a private owned directory")
                    process.stdin.write(b"continue\n")
                elif line in {b"SERVER_READY\n", b"BEFORE_CLEANUP\n"}:
                    remember()
                    if line == b"BEFORE_CLEANUP\n" and command("list-clients"):
                        raise RuntimeError("an example left clients attached")
                    process.stdin.write(b"continue\n")
        _, error = process.communicate(timeout=1)
        if process.returncode or error:
            raise RuntimeError((process.returncode, b"".join(output), error))
        text = b"".join(output)
        for expected in [b'session $0 "demo"', b"active=%0\nroomy=%0\nsessions=demo\n",
                         b"session=$1\n", b"rendered_pane=%0\n"]:
            if expected not in text:
                raise RuntimeError(("missing README result", expected, text))
        if directory.exists():
            raise RuntimeError("README cleanup left its directory")
        for descriptor in pidfds.values():
            with selectors.DefaultSelector() as exited:
                exited.register(descriptor, selectors.EVENT_READ)
                if not exited.select(1):
                    raise RuntimeError("README cleanup left an owned process alive")
        os.waitpid(daemon, 0)
        daemon = None
        print(f"literal README demo commands: PASS ({Path(binary).parent.name})")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        if directory is not None and directory.exists() and daemon is None and (directory / "server").exists():
            remember()
        if daemon is not None:
            try:
                signal.pidfd_send_signal(pidfds[daemon], signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(daemon, 0)
        for descriptor in pidfds.values():
            os.close(descriptor)
        for stream in [process.stdin, process.stdout, process.stderr]:
            stream.close()
        if directory is not None and directory.exists():
            shutil.rmtree(directory)
