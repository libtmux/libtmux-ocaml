"""Execute literal documentation commands using installed example programs."""

import ctypes
import os
import re
import selectors
import shlex
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path


def prepare(root, temporary, environment):
    project = temporary / "readme-walkthrough"
    project.mkdir()
    (project / "dune-project").write_text("(lang dune 3.24)\n")
    examples = project / "examples"
    examples.mkdir()
    for source in (root / "examples").iterdir():
        if source.name == "dune" or source.suffix == ".ml":
            shutil.copyfile(source, examples / source.name)
    subprocess.run(
        ["dune", "build", "--root", str(project)],
        cwd=project,
        env=environment,
        check=True,
        capture_output=True,
    )
    library = subprocess.check_output(
        ["opam", "exec", "--", "ocamlfind", "query", "libtmux"],
        cwd=project,
        env=environment,
        text=True,
    ).strip()
    if Path(library) != Path(environment["OCAMLPATH"]) / "libtmux":
        raise RuntimeError("README commands did not use the independent installation")
    return project


EXPECTED = {
    "docs/recovery.md": [
        b"waiter=cancelled; operation=retained\n",
        b"operation=finished; postcondition=recovery-complete\n",
        b"cleanup-issues=0; omitted=0\n",
    ],
    "docs/hook-recovery.md": [
        b"operation=unknown\n",
        b"hook failed or emitted output",
        b"reported-window=@1; reported-pane=%1\n",
        b"cleanup-issues=0; omitted=0\n",
    ],
    "docs/workspace-recovery.md": [
        b"waiter=cancelled\npostcondition=created-session-absent\n",
        b"journal=interrupted\ncompensated-pane=%1\n",
        b"cleanup-issues=0; omitted=0\n",
    ],
    "docs/streaming.md": [
        b"gap=membership-changed; history=unavailable\n",
        b"coverage=fresh; cursor-generation=new; future=after-gap\n",
    ],
}


def guide_command(root, document):
    """Return the one `dune exec` command a guide shows, split into arguments."""
    blocks = re.findall(
        r"```console\n(.*?)```", (root / document).read_text(), re.DOTALL
    )
    commands = [
        block[2:].strip()
        for block in blocks
        if block.startswith("$ opam exec -- dune exec examples/")
    ]
    if len(commands) != 1 or any("mktemp" in block for block in blocks):
        raise ValueError(f"{document} must show one command and no shell setup")
    arguments = shlex.split(commands[0])
    if arguments[-1] != "tmux":
        raise ValueError(f"{document} must pass tmux as the program's argument")
    return arguments


def run(root, project, binary, environment, document):
    """Run a guide's command and check its output and owned teardown."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0):
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    child_file = Path(f"/proc/self/task/{os.getpid()}/children")
    previous_children = set(map(int, child_file.read_text().split()))
    command = [
        *guide_command(root, document)[:-1],
        str(Path(binary).resolve(strict=True)),
    ]
    with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-walkthrough-") as runtime:
        child_environment = dict(
            environment,
            TMPDIR=runtime,
            TMUX="/unrelated/server,99999,0",
            TMUX_PANE="%99999",
        )
        result = subprocess.run(
            command,
            cwd=project,
            env=child_environment,
            capture_output=True,
            timeout=5,
            check=False,
        )
        if result.returncode or result.stderr:
            raise RuntimeError(
                (document, result.returncode, result.stdout, result.stderr)
            )
        for expected in EXPECTED[document]:
            if expected not in result.stdout:
                raise RuntimeError(
                    ("missing documentation result", expected, result.stdout)
                )
        if list(Path(runtime).iterdir()):
            raise RuntimeError(f"{document} left a private directory behind")
    for pid in set(map(int, child_file.read_text().split())) - previous_children:
        try:
            descriptor = os.pidfd_open(pid)
        except ProcessLookupError:
            continue
        try:
            with selectors.DefaultSelector() as exited:
                exited.register(descriptor, selectors.EVENT_READ)
                if not exited.select(1):
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                    raise RuntimeError(f"{document} left an owned descendant alive")
            os.waitpid(pid, 0)
        finally:
            os.close(descriptor)
    print(f"{document} command: PASS ({Path(binary).parent.name})")
