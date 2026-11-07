"""Measure attributed Eio requests, future output and cancellation on owned tmux."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import resource
import selectors
import statistics
import subprocess
import sys
import time

from capture import ROOT, source_digest

sys.path.insert(0, str(ROOT / "test"))
from support.tmux_fixture import TmuxFixture


def child_count(pid):
    children = set()
    for task in (Path("/proc") / str(pid) / "task").iterdir():
        children.update((task / "children").read_text().split())
    return len(children)


def stage(process, expected, response):
    with selectors.DefaultSelector() as ready:
        ready.register(process.stdout, selectors.EVENT_READ)
        if not ready.select(1):
            raise TimeoutError(f"benchmark did not reach {expected!r}")
    actual = process.stdout.readline()
    if actual != expected:
        raise RuntimeError(("unexpected benchmark stage", actual))
    count = child_count(process.pid)
    process.stdin.write(response)
    process.stdin.flush()
    return count


def sample(fixture, args):
    started = time.perf_counter()
    usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    process = subprocess.Popen(
        [str(ROOT / "_build/default/bench/concurrency.exe"), fixture.binary,
         str(fixture.socket), str(args.requests), str(args.concurrency),
         str(args.streams), str(args.cancels)],
        cwd=ROOT, env=fixture.environment, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        primary_children = stage(process, b"READY\n", b"run\n")
        stream_children = stage(process, b"STREAM_READY\n", b"stream\n")
        output, error = process.communicate(timeout=30)
        seconds = time.perf_counter() - started
        usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        if process.returncode or error:
            raise RuntimeError((process.returncode, output, error))
        result = json.loads(output)
        rows = result["requests"]["rows"]
        if [(row["index"], row["value"]) for row in rows] != [
                (index, f"value-{index % args.concurrency}") for index in range(args.requests)]:
            raise RuntimeError("concurrent request ordering or attribution differs")
        if primary_children != 1 or stream_children != 2 or result["max_clients"] != 2:
            raise RuntimeError("unexpected primary/stream clients or child processes")
        if len(result["stream_seconds"]) != args.streams or len(result["cancellation_seconds"]) != args.cancels:
            raise RuntimeError("missing stream or cancellation observations")
        if fixture.command("list-clients").stdout:
            raise RuntimeError("benchmark left clients attached")
        result.update(whole_sample_seconds=seconds, primary_child_processes=primary_children,
                      stream_child_processes=stream_children,
                      child_cpu_seconds=usage_after.ru_utime + usage_after.ru_stime
                      - usage_before.ru_utime - usage_before.ru_stime)
        return result
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=1)
        for stream in [process.stdin, process.stdout, process.stderr]:
            stream.close()


def distribution(values):
    ordered = sorted(values)
    return {"count": len(values), "min_seconds": ordered[0],
            "median_seconds": statistics.median(ordered),
            "p95_seconds": ordered[math.ceil(len(ordered) * .95) - 1],
            "max_seconds": ordered[-1]}


def main():
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--requests", type=int, default=128)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--streams", type=int, default=10)
    parser.add_argument("--cancels", type=int, default=10)
    parser.add_argument("--repeat", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for name, maximum in [("requests", 1000), ("concurrency", 64), ("streams", 100), ("cancels", 100), ("repeat", 20)]:
        if not 1 <= getattr(args, name) <= maximum:
            parser.error(f"{name} must be 1..{maximum}")
    if args.output.exists():
        parser.error("output exists; choose another file")
    load = os.getloadavg()
    with TmuxFixture(args.binary) as fixture:
        marker = fixture.socket.parent / "ready.txt"
        marker.write_text("bench ready\n")
        # Disable terminal echo before the readiness marker: streams observe cat's output.
        fixture.command("respawn-pane", "-k", "-t", "%0", "/bin/sh", "-c",
                        'stty -echo; exec /bin/cat -u "$1" -', "benchmark", str(marker))
        fixture.track_panes()
        settings = []
        for index in range(args.concurrency):
            if settings:
                settings.append(";")
            settings.extend(["set-option", "-t", "$0", f"@bench-{index}", f"value-{index}"])
        fixture.command(*settings)
        samples = [sample(fixture, args) for _ in range(args.repeat)]
        version = fixture.command("display-message", "-p", "#{version}").stdout.decode().strip()
    result = {
        "schema": "libtmux.concurrency-benchmark/1",
        "measured_at_utc": datetime.datetime.now(datetime.UTC).isoformat(),
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": source_digest(),
        "compiler": subprocess.check_output(["ocamlc", "-version"], text=True).strip(),
        "tmux": version, "binary_sha256": hashlib.sha256(Path(fixture.binary).read_bytes()).hexdigest(),
        "platform": {"system": platform.system(), "kernel": platform.release(),
                     "architecture": platform.machine(), "available_cpus": len(os.sched_getaffinity(0)),
                     "load_average_start": list(load)},
        "workload": {key: getattr(args, key) for key in ["requests", "concurrency", "streams", "cancels", "repeat"]},
        "samples": samples,
        "summary": {
            "request_latency": distribution([row["seconds"] for sample_ in samples for row in sample_["requests"]["rows"]]),
            "stream_latency": distribution([value for sample_ in samples for value in sample_["stream_seconds"]]),
            "cancellation_latency": distribution([value for sample_ in samples for value in sample_["cancellation_seconds"]]),
            "median_requests_per_second": statistics.median(args.requests / sample_["requests"]["seconds"] for sample_ in samples),
        },
        "whole_command_seconds": time.perf_counter() - started,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))
    print("PASS attributed ordered requests, future output, cancellation, bounded clients and owned teardown")


if __name__ == "__main__":
    main()
