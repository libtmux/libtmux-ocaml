"""Measure live OCaml heap retained by repeated real graph captures."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

from capture import ROOT, TmuxFixture, source_digest

MODES = ["discard", "snapshots", "panes", "latest-pane", "summaries", "targets"]


def main():
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--captures", type=int, default=100)
    parser.add_argument("--windows", type=int, default=16)
    parser.add_argument("--repeat", type=int, default=6)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.captures <= 512 or not 1 <= args.windows <= 128:
        parser.error("captures must be 1..512 and windows 1..128")
    if not 1 <= args.repeat <= 8:
        parser.error("repeat must be 1..8")
    if args.output.exists():
        parser.error("output exists; choose another file")
    executable = ROOT / "_build/default/bench/retention.exe"
    result = {
        "schema": "libtmux.retention-benchmark/1",
        "status": "RUNNING",
        "measured_at_utc": datetime.datetime.now(datetime.UTC).isoformat(),
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": source_digest(),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "compiler": subprocess.check_output(["ocamlc", "-version"], text=True).strip(),
        "platform": {"system": platform.system(), "kernel": platform.release(),
                     "architecture": platform.machine(), "available_cpus": len(os.sched_getaffinity(0)),
                     "load_average_start": list(os.getloadavg())},
        "workload": {"sessions": 1, "windows": args.windows, "panes": args.windows,
                     "captures_per_sample": args.captures, "samples_per_mode": args.repeat},
        "samples": {mode: [] for mode in MODES},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with TmuxFixture(args.binary) as fixture:
            result["tmux"] = fixture.command("display-message", "-p", "#{version}").stdout.decode().strip()
            result["binary_sha256"] = hashlib.sha256(Path(fixture.binary).read_bytes()).hexdigest()
            for index in range(1, args.windows):
                fixture.command("new-window", "-d", "-t", "$0:", "-n", f"retention-{index}", "exec cat")
                fixture.track_panes()
            for repetition in range(args.repeat):
                order = MODES[repetition % len(MODES):] + MODES[:repetition % len(MODES)]
                for mode in order:
                    tick = time.perf_counter()
                    process = subprocess.run(
                        [str(executable), fixture.binary, str(fixture.socket), mode,
                         str(args.captures), str(args.windows)], cwd=ROOT,
                        env=fixture.environment, capture_output=True, timeout=30,
                    )
                    if process.returncode or process.stderr:
                        raise RuntimeError((mode, process.returncode, process.stdout.decode(), process.stderr.decode()))
                    sample = json.loads(process.stdout)
                    expected = 0 if mode == "discard" else 1 if mode == "latest-pane" else args.captures
                    if sample["retained_values"] != expected:
                        raise RuntimeError("retention roots differ from requested policy")
                    if fixture.command("list-clients").stdout:
                        raise RuntimeError("benchmark left a client attached")
                    sample["sample_seconds"] = time.perf_counter() - tick
                    result["samples"][mode].append(sample)
        result["owned_teardown"] = "PASS"
        result["summary"] = {
            mode: {key: {"median": statistics.median(sample[key] for sample in samples),
                         "min": min(sample[key] for sample in samples),
                         "max": max(sample[key] for sample in samples)}
                   for key in ["retained_delta_bytes", "released_delta_bytes", "loop_allocated_bytes"]}
            for mode, samples in result["samples"].items()
        }
        result["status"] = "PASS"
    except BaseException as error:
        result["status"] = "FAIL"
        result["failure"] = repr(error)
        raise
    finally:
        result["whole_command_seconds"] = time.perf_counter() - started
        result["platform"]["load_average_end"] = list(os.getloadavg())
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({mode: summary["retained_delta_bytes"] for mode, summary in result["summary"].items()}, indent=2))
    print("PASS fixed topology, retained root counts, client closure and owned teardown")


if __name__ == "__main__":
    main()
