"""Collect first-close evidence for the ordinary stream-gap recovery example.

This manual diagnostic does not change the production client. A copied module
adds logging at its existing close/error paths. No reproduction is not a pass
for the original failing workload.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time

from support.tmux_fixture import TmuxFixture

ROOT = Path(__file__).resolve().parents[1]


def instrument(source):
    prefix = '''module Runtime = Libtmux_eio__Runtime
module Owned_process = Libtmux_eio__Owned_process
module Generated_operations = Libtmux_eio__Generated_operations
let trace label =
  let output = open_out_gen [Open_wronly; Open_creat; Open_append; Open_text] 0o600
      (Sys.getenv "LIBTMUX_CLOSE_TRACE") in
  Fun.protect ~finally:(fun () -> close_out output) (fun () ->
      Printf.fprintf output "%s\\n%s\\n%!" label
        (Printexc.raw_backtrace_to_string (Printexc.get_callstack 40)))
'''
    needle = 'if not t.closing then (\n          t.closing <- true;'
    if source.count(needle) != 1:
        raise ValueError("first-close instrumentation no longer matches source")
    source = source.replace(needle, 'if not t.closing then (\n          trace "first-close";\n          t.closing <- true;')
    needle = 'match protect pump with Ok () -> () | Error _ -> close_exn t'
    if source.count(needle) != 1:
        raise ValueError("pump instrumentation no longer matches source")
    source = source.replace(needle, 'match protect pump with Ok () -> () | Error error -> trace (Format.asprintf "pump error: %a" Error.pp error); close_exn t')
    first, worker = source.split('  let worker ~sw t f =', 1)
    worker, rest = worker.split('  let idle_events t =', 1)
    if worker.count('let bt = Printexc.get_raw_backtrace () in') != 2:
        raise ValueError("worker instrumentation no longer matches source")
    worker = worker.replace('let bt = Printexc.get_raw_backtrace () in', 'trace ("worker exception: " ^ Printexc.to_string exn);\n            let bt = Printexc.get_raw_backtrace () in')
    return prefix + first + '  let worker ~sw t f =' + worker + '  let idle_events t =' + rest


def main():
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--repeat", type=int, default=20)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error("repeat must be 1..20")
    args.output.mkdir(parents=True, exist_ok=False)
    output = args.output.resolve()
    binary = str(Path(args.binary).resolve(strict=True))
    original = (ROOT / "eio/libtmux_eio.ml").read_text()
    diagnostic = instrument(original)
    peer = (ROOT / "examples/native_stream_recovery.ml").read_text().replace('Libtmux_eio.', 'Diagnostic_eio.')
    (output / "diagnostic_eio.ml").write_text(diagnostic)
    (output / "peer.ml").write_text(peer)
    report = {
        "status": "ERROR", "attempts": [],
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "compiler": subprocess.check_output(["ocamlc", "-version"], text=True).strip(),
        "original_client_sha256": hashlib.sha256(original.encode()).hexdigest(),
        "instrumented_client_sha256": hashlib.sha256(diagnostic.encode()).hexdigest(),
        "peer_sha256": hashlib.sha256(peer.encode()).hexdigest(),
        "tmux_binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        "kernel": platform.release(),
        "backend_selection": os.environ.get("EIO_BACKEND", "default"),
        "load_average_start": list(os.getloadavg()),
    }
    try:
        with tempfile.TemporaryDirectory(prefix="libtmux-ocaml-close-diagnostic-") as directory:
            temporary = Path(directory)
            prefix = temporary / "installed"
            subprocess.run(["dune", "install", "--root", str(ROOT), "--prefix", str(prefix),
                            "libtmux", "libtmux-workspace", "libtmux-json", "libtmux-unix", "libtmux-eio"],
                           check=True, stdout=subprocess.DEVNULL)
            environment = dict(os.environ, OCAMLPATH=str(prefix / "lib"), OCAMLRUNPARAM="b")
            for key in ("DUNE_SOURCEROOT", "DUNE_WORKSPACE", "TMUX", "TMUX_PANE"):
                environment.pop(key, None)
            project = temporary / "consumer"
            project.mkdir()
            (project / "dune-project").write_text("(lang dune 3.24)\n")
            (project / "dune").write_text("(executable (name main) (modules main diagnostic_eio) (libraries libtmux libtmux-eio eio_main))\n")
            (project / "main.ml").write_text(peer)
            (project / "diagnostic_eio.ml").write_text(diagnostic)
            build = subprocess.run(["dune", "build", "--root", str(project)], env=environment, capture_output=True)
            (output / "build.stdout").write_bytes(build.stdout)
            (output / "build.stderr").write_bytes(build.stderr)
            build.check_returncode()
            report["executable_sha256"] = hashlib.sha256((project / "_build/default/main.exe").read_bytes()).hexdigest()
            report["status"] = "NO_REPRODUCTION"
            for index in range(args.repeat):
                path = output / f"case-{index:02d}.trace"
                with TmuxFixture(binary) as fixture:
                    before = fixture.command("list-panes", "-a", "-F", "#{pane_id}:#{window_id}").stdout
                    env = dict(environment, LIBTMUX_CLOSE_TRACE=str(path))
                    row = {"index": index, "timeout": False}
                    try:
                        result = subprocess.run([str(project / "_build/default/main.exe"),
                                                 fixture.binary, str(fixture.socket), "$0"],
                                                env=env, capture_output=True, timeout=1)
                        stdout, stderr = result.stdout, result.stderr
                        row["exit"] = result.returncode
                    except subprocess.TimeoutExpired as error:
                        stdout, stderr = error.stdout or b"", error.stderr or b""
                        row.update(exit=None, timeout=True)
                    (output / f"case-{index:02d}.stdout").write_bytes(stdout)
                    (output / f"case-{index:02d}.stderr").write_bytes(stderr)
                    row.update(daemon_alive=fixture.server.poll() is None,
                               trace=path.name)
                    if row["daemon_alive"]:
                        try:
                            fixture.track_panes()
                            row["clients_after"] = len(fixture.command("list-clients").stdout.splitlines())
                            after = fixture.command("list-panes", "-a", "-F", "#{pane_id}:#{window_id}").stdout
                            row["panes_unchanged"] = after == before
                            row["pane_inventory_after"] = after.decode().splitlines()
                        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
                            row["inspection_error"] = repr(error)
                    report["attempts"].append(row)
                    print(json.dumps(row), flush=True)
                    expected_stdout = (b"gap=membership-changed; history=unavailable\n"
                                       b"coverage=fresh; cursor-generation=new; future=after-gap\n")
                    original_failure = (
                        not row["timeout"] and row["exit"] != 0 and stdout == expected_stdout
                        and b'Failure("outcome unknown: client is closed")' in stderr)
                    normal = (row["exit"] == 0 and stdout == expected_stdout and stderr == b""
                              and row["daemon_alive"] and row.get("clients_after") == 0
                              and row.get("panes_unchanged") and path.exists())
                    if not normal:
                        report["status"] = "REPRODUCED" if original_failure else "DIFFERENT_FAILURE"
                        break
    except BaseException as error:
        report["status"] = "ERROR"
        report["error"] = repr(error)
        raise
    finally:
        report["whole_command_seconds"] = time.perf_counter() - started
        report["load_average_end"] = list(os.getloadavg())
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Diagnostic outcome:", report["status"], flush=True)
    return 0 if report["status"] == "NO_REPRODUCTION" else 2


if __name__ == "__main__":
    sys.exit(main())
