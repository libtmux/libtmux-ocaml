"""Outer: compile whole showcase programs against installed packages and run their entry points."""
import ctypes
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "examples/showcase.json").read_text())
programs = {}
for entry in manifest["examples"]:
    path = (root / entry["file"]).resolve()
    assert path.parent == root / "examples" and path.suffix == ".ml"
    assert entry["whole_file"] and entry["success_exit_code"] == 0
    executable = str(Path(entry["file"]).with_suffix(".exe"))
    assert entry["command"] == ["opam", "exec", "--", "dune", "exec", executable, "--", "tmux"], \
        "showcase command does not execute its recorded source"
    assert path.stem not in programs, "duplicate showcase program"
    programs[path.stem] = entry
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0):
    raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
child_file = Path(f"/proc/self/task/{os.getpid()}/children")


def children():
    return set(map(int, child_file.read_text().split()))


with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-showcase-consumer-") as temporary:
    temporary = Path(temporary)
    prefix = temporary / "installed"
    packages = ["libtmux", "libtmux-workspace", "libtmux-unix", "libtmux-eio"]
    subprocess.run(["dune", "install", "--sections=lib,stublibs", "--prefix", str(prefix), *packages],
                   cwd=root, check=True, capture_output=True)
    project = temporary / "consumer"
    project.mkdir()
    runtime_temp = temporary / "runtime-temp"
    runtime_temp.mkdir(mode=0o700)
    (project / "dune-project").write_text("(lang dune 3.24)\n")
    examples = project / "examples"
    examples.mkdir()
    blocking = " ".join(name for name in programs if name != "showcase_watch")
    (examples / "dune").write_text("(executables (names " + blocking + ") (modules " + blocking +
        ") (libraries libtmux libtmux-workspace libtmux-unix unix))\n" +
        "(executable (name showcase_watch) (modules showcase_watch) " +
        "(libraries libtmux libtmux-workspace libtmux-unix libtmux-eio eio_main unix))\n")
    for name in programs:
        source = root / "examples" / f"{name}.ml"
        assert source.is_file(), f"missing standalone showcase: {name}"
        (examples / source.name).write_bytes(source.read_bytes())
    environment = dict(os.environ, OCAMLPATH=str(prefix / "lib"), TMPDIR=str(runtime_temp),
                       TMUX="/unrelated/server,99999,0", TMUX_PANE="%99999")
    for key in ["DUNE_SOURCEROOT", "DUNE_WORKSPACE"]:
        environment.pop(key, None)
    environment["OPAMSWITCH"] = subprocess.check_output(
        ["opam", "switch", "show", "--safe"], cwd=root, env=environment, text=True).strip()
    resolved = subprocess.check_output(["opam", "exec", "--", "ocamlfind", "query", *packages],
                                       cwd=project, env=environment, text=True).splitlines()
    assert list(map(Path, resolved)) == [prefix / "lib" / package for package in packages]
    built = subprocess.run(["dune", "build", "--root", str(project)],
                           cwd=project, env=environment, capture_output=True)
    assert built.returncode == 0, (built.stdout + built.stderr).decode(errors="replace")
    for index, binary in enumerate(sys.argv[1:]):
        actual = str(Path(binary).resolve(strict=True))
        fault = temporary / f"fault-tmux-{index}"
        audit = temporary / f"fault-directory-{index}"
        fault.write_text("#!/usr/bin/env python3\nimport os,sys\nfrom pathlib import Path\n" +
            "args=sys.argv[1:]\nif '-C' in args and 'new-session' in args:\n" +
            " p=Path(args[args.index('-f')+1])\n" +
            f" Path({str(audit)!r}).write_text(str(p.parent))\n" +
            " with p.open('a') as output:\n" +
            "  session=os.environ['LIBTMUX_SHOWCASE_COLLISION']\n" +
            "  output.write(f'new-session -d -s {session} -- /bin/cat -u\\n')\n" +
            f"os.execv({actual!r}, [{actual!r}, *args])\n")
        fault.chmod(0o700)
        cases = [(name, entry, actual, False) for name, entry in programs.items()]
        cases.append(("showcase_create_window", programs["showcase_create_window"], str(fault), True))
        cases.append(("showcase_bootstrap", programs["showcase_bootstrap"], str(fault), True))
        for name, entry, program, should_fail in cases:
            previous = children()
            command = [*entry["command"][:-1], program]
            process = subprocess.Popen(command,
                                       cwd=project, env=dict(environment, LIBTMUX_SHOWCASE_COLLISION=
                                           "bootstrap-demo" if name == "showcase_bootstrap" else "showcase"),
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE)
            try:
                output, error = process.communicate(timeout=1)
                if should_fail:
                    assert process.returncode == 2 and error, (name, process.returncode, output, error)
                    assert entry["expected_stdout_line"].encode() not in output.splitlines()
                    if name == "showcase_bootstrap":
                        assert b"workspace " in error and b" did not complete" in error, error
                        assert b"new-session" in error and b"no automatic retry" in error, error
                    directory = Path(audit.read_text())
                else:
                    assert process.returncode == 0 and not error, (name, process.returncode, output, error)
                    assert entry["expected_stdout_line"].encode() in output.splitlines(), \
                        (name, "missing expected outcome", output)
                    socket_line = next(line for line in output.splitlines() if line.startswith(b"socket="))
                    directory = Path(os.fsdecode(socket_line[len(b"socket="):])).parent
                assert directory.name.startswith("libtmux-ocaml-showcase-")
                assert not directory.exists(), "showcase left its private directory"
                for pid in children() - previous:
                    descriptor = os.pidfd_open(pid)
                    try:
                        with selectors.DefaultSelector() as ready:
                            ready.register(descriptor, selectors.EVENT_READ)
                            assert ready.select(1), f"{name} left owned child {pid} running"
                        os.waitpid(pid, 0)
                    finally:
                        os.close(descriptor)
                outcome = "startup failure" if should_fail else "installed entry point"
                print(f"PASS {Path(binary).parent.name}: {name}, {outcome} and owned teardown")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
                while children() - previous:
                    for pid in children() - previous:
                        descriptor = os.pidfd_open(pid)
                        try:
                            try:
                                signal.pidfd_send_signal(descriptor, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            with selectors.DefaultSelector() as ready:
                                ready.register(descriptor, selectors.EVENT_READ)
                                assert ready.select(1), "owned showcase child did not terminate"
                            os.waitpid(pid, 0)
                        finally:
                            os.close(descriptor)
                process.stdout.close()
                process.stderr.close()
                for path in runtime_temp.iterdir():
                    if path.is_dir():
                        shutil.rmtree(path)
                    else:
                        path.unlink()
