"""Benchmark serial graph capture with equivalent query results and owned teardown."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import selectors
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test"))
from support.tmux_fixture import TmuxFixture


def source_digest():
    digest = hashlib.sha256()
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT).split(b"\0")
    for name in sorted(set(filter(None, names))):
        path = Path(os.fsdecode(name))
        behavior = name.startswith((b"lib/", b"unix/", b"eio/", b"bench/")) and (
            path.suffix in {".ml", ".mli", ".py", ".c", ".h"} or path.name == "dune")
        if behavior or name.endswith(b".opam") or name == b"dune-project":
            digest.update(name + b"\0" + (ROOT / os.fsdecode(name)).read_bytes() + b"\0")
    return digest.hexdigest()


def sample(fixture, backend, iterations):
    def daemon_cpu():
        fields = (Path("/proc") / str(fixture.server.pid) / "stat").read_text().rsplit(") ", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")

    start = time.perf_counter()
    daemon_before = daemon_cpu()
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.Popen([str(ROOT / "_build/default/bench/capture.exe"), fixture.binary,
                                str(fixture.socket), backend, str(iterations)],
                               cwd=ROOT, env=fixture.environment, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ)
            if not ready.select(1):
                raise TimeoutError("benchmark did not initialize")
        if process.stdout.readline() != b"READY\n":
            raise RuntimeError("benchmark did not become ready")
        children = set()
        for task in (Path("/proc") / str(process.pid) / "task").iterdir():
            children.update((task / "children").read_text().split())
        process.stdin.write(b"run\n")
        process.stdin.flush()
        output, error = process.communicate(timeout=30)
        elapsed = time.perf_counter() - start
        usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        if process.returncode or error:
            raise RuntimeError((process.returncode, output, error))
        result = json.loads(output)
        if len(children) != 1 or result["max_clients"] != 1:
            raise RuntimeError("unexpected client or subprocess count")
        if fixture.command("list-clients").stdout:
            raise RuntimeError("benchmark left clients attached")
        cpu = (usage_after.ru_utime + usage_after.ru_stime
               - usage_before.ru_utime - usage_before.ru_stime)
        return elapsed, result, len(children), cpu, daemon_cpu() - daemon_before
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        for stream in [process.stdin, process.stdout, process.stderr]:
            stream.close()


def main():
    whole_start = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--windows", type=int, default=4)
    parser.add_argument("--panes-per-window", type=int, default=4)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 1000 or not 1 <= args.repeat <= 20:
        parser.error("iterations must be 1..1000 and repeat 1..20")
    if not 1 <= args.windows <= 16 or not 1 <= args.panes_per_window <= 16:
        parser.error("windows and panes-per-window must each be 1..16")
    if args.output.exists():
        parser.error("output exists; choose another file")
    records = {"unix": [], "eio": []}
    load = os.getloadavg()
    with TmuxFixture(args.binary) as fixture:
        fixture.command("respawn-pane", "-k", "-t", "%0", "/bin/cat", "-u")
        first_panes = ["%0"]
        for index in range(1, args.windows):
            first_panes.append(fixture.command("new-window", "-d", "-P", "-F", "#{pane_id}",
                                               "-t", "$0:", "-n", f"bench-{index}", "/bin/cat", "-u").stdout.decode().strip())
        for pane in first_panes:
            fixture.command("resize-window", "-t", pane, "-x", str(max(80, args.panes_per_window * 6)))
            for _ in range(args.panes_per_window - 1):
                fixture.command("split-window", "-d", "-h", "-t", pane, "/bin/cat", "-u")
                fixture.command("select-layout", "-t", pane, "even-horizontal")
        fixture.track_panes()
        expected = []
        for row in fixture.command("list-panes", "-a", "-F", "#{pane_id}|#{pane_active}").stdout.decode().splitlines():
            pane, active = row.split("|")
            if active == "1":
                expected.append(pane)
        for repetition in range(args.repeat):
            order = ["unix", "eio"] if repetition % 2 == 0 else ["eio", "unix"]
            for backend in order:
                elapsed, result, children, cpu, daemon_cpu = sample(fixture, backend, args.iterations)
                if result["results"] != [expected] * args.iterations:
                    raise RuntimeError((backend, "captured query order or values differ", expected, result["results"][:2]))
                records[backend].append({"seconds": elapsed, "child_processes": children,
                                         "observed_clients": result["max_clients"], "child_cpu_seconds": cpu,
                                         "daemon_cpu_seconds": daemon_cpu,
                                         "loop_allocated_bytes": result["loop_allocated_bytes"]})
        version = fixture.command("display-message", "-p", "#{version}").stdout.decode().strip()
    result = {"schema": "libtmux.benchmark/1", "measured_at_utc": datetime.datetime.now(datetime.UTC).isoformat(),
              "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "source_sha256": source_digest(), "compiler": subprocess.check_output(["ocamlc", "-version"], text=True).strip(),
              "tmux": version, "binary_sha256": hashlib.sha256(Path(fixture.binary).read_bytes()).hexdigest(),
              "platform": {"system": platform.system(), "kernel": platform.release(), "architecture": platform.machine(),
                           "available_cpus": len(os.sched_getaffinity(0)), "load_average_start": list(load)},
              "workload": {"sessions": 1, "windows": args.windows,
                           "panes": args.windows * args.panes_per_window, "captures": args.iterations, "selected_ids": expected},
              "samples": records, "summary": {backend: {"median_seconds": statistics.median(r["seconds"] for r in samples),
                                                        "min_seconds": min(r["seconds"] for r in samples), "max_seconds": max(r["seconds"] for r in samples)}
                                                 for backend, samples in records.items()}}
    result["whole_command_seconds"] = time.perf_counter() - whole_start
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))
    print("PASS same captured queries, order, one client/child per mode and owned teardown")


if __name__ == "__main__":
    main()
