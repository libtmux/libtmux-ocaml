"""Measure completed control-lane mutations on fixed, owned tmux fixtures."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import selectors
import shlex
import signal
import statistics
import subprocess
import sys
import time

from capture import ROOT, TmuxFixture, source_digest
from concurrency import child_count, distribution


class BenchmarkFixture(TmuxFixture):
    def close(self):
        primary = sys.exception()
        try:
            super().close()
        except BaseException as cleanup:
            if primary is None:
                raise
            primary.add_note("fixture cleanup: " + repr(cleanup))


def barrier(process, expected, timeout):
    with selectors.DefaultSelector() as ready:
        ready.register(process.stdout, selectors.EVENT_READ)
        if not ready.select(timeout):
            raise TimeoutError(f"benchmark did not reach {expected!r}")
    actual = process.stdout.readline()
    if actual != expected:
        raise RuntimeError(("unexpected benchmark stage", actual))


def sample(binary, requests, concurrency):
    started = time.perf_counter()
    with BenchmarkFixture(binary) as fixture:
        directory = Path(fixture.directory.name)
        launches = directory / "client-launches"
        wrapper = directory / "tmux-client"
        wrapper.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$$\" >> " + shlex.quote(str(launches))
            + "\nexec " + shlex.quote(fixture.binary) + ' "$@"\n'
        )
        wrapper.chmod(0o700)
        helpers = {}
        usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        process = subprocess.Popen(
            [str(ROOT / "_build/default/bench/control.exe"), str(wrapper),
             str(fixture.socket), str(requests), str(concurrency)],
            cwd=ROOT, env=fixture.environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        try:
            barrier(process, b"READY\n", 1)
            for pid in launches.read_text().splitlines():
                helpers[int(pid)] = os.pidfd_open(int(pid))
            if len(helpers) != 1 or child_count(process.pid) != 1:
                raise RuntimeError("expected one persistent tmux child")
            process.stdin.write(b"continue\n")
            barrier(process, b"DONE\n", 1)
            if len(launches.read_text().splitlines()) != 1 or child_count(process.pid) != 1:
                raise RuntimeError("mutation phase started another tmux process")
            if len(fixture.command("list-clients").stdout.splitlines()) != 1:
                raise RuntimeError("mutation phase changed client topology")
            process.stdin.write(b"continue\n")
            output, error = process.communicate(timeout=1)
            usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
            if process.returncode or error:
                raise RuntimeError((process.returncode, output, error))
            result = json.loads(output)
            expected = [(index, f"@control-bench-{index:04d}", f"value-{index:04d}")
                        for index in range(requests)]
            rows = result["rows"]
            if [(row["index"], row["name"], row["value"]) for row in rows] != expected:
                raise RuntimeError("completed mutations differ from submitted input")
            if len({row["operation_id"] for row in rows}) != requests:
                raise RuntimeError("mutation handles reused operation IDs")
            verify_started = time.perf_counter()
            table = fixture.command("show-options", "-t", "$0").stdout.decode().splitlines()
            actual = dict(line.split(" ", 1) for line in table
                          if line.startswith("@control-bench-"))
            if actual != {name: value for _, name, value in expected}:
                raise RuntimeError("server postconditions differ from completed mutations")
            if fixture.command("list-clients").stdout:
                raise RuntimeError("benchmark left clients attached")
            result.update(
                verification_seconds=time.perf_counter() - verify_started,
                client_process_launches=1, helper_reaping="PASS",
                helper_observation_start="READY",
                consumer_and_topology_cpu_seconds=usage_after.ru_utime + usage_after.ru_stime
                - usage_before.ru_utime - usage_before.ru_stime,
            )
            for descriptor in helpers.values():
                with selectors.DefaultSelector() as exited:
                    exited.register(descriptor, selectors.EVENT_READ)
                    if not exited.select(1):
                        raise RuntimeError("owned tmux client did not exit")
        finally:
            cleanup_errors = []
            try:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=1)
            except BaseException as error:
                cleanup_errors.append(error)
            for stream in [process.stdin, process.stdout, process.stderr]:
                try:
                    stream.close()
                except BaseException as error:
                    cleanup_errors.append(error)
            for descriptor in helpers.values():
                try:
                    with selectors.DefaultSelector() as exited:
                        exited.register(descriptor, selectors.EVENT_READ)
                        if not exited.select(1):
                            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                            if not exited.select(1):
                                raise RuntimeError("owned tmux client survived forced termination")
                except BaseException as error:
                    cleanup_errors.append(error)
                finally:
                    try:
                        os.close(descriptor)
                    except BaseException as error:
                        cleanup_errors.append(error)
            if cleanup_errors:
                primary = sys.exception()
                if primary is None:
                    primary, *others = cleanup_errors
                    for error in others:
                        primary.add_note("benchmark cleanup: " + repr(error))
                    raise primary
                for error in cleanup_errors:
                    primary.add_note("benchmark cleanup: " + repr(error))
        version = fixture.command("display-message", "-p", "#{version}").stdout.decode().strip()
    result.update(sample_seconds=time.perf_counter() - started,
                  owned_teardown="PASS", tmux=version)
    return result


def main():
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--requests", type=int, default=128)
    parser.add_argument("--concurrency", nargs="+", type=int, default=[1, 8, 32])
    parser.add_argument("--repeat", type=int, default=6)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.requests <= 512 or not 1 <= args.repeat <= 8:
        parser.error("requests must be 1..512; repeat must be 1..8")
    if len(set(args.concurrency)) != len(args.concurrency) or not args.concurrency:
        parser.error("concurrency values must be nonempty and unique")
    if any(not 1 <= value <= 32 for value in args.concurrency):
        parser.error("concurrency must be 1..32")
    if args.output.exists():
        parser.error("output exists; choose another file")
    binary = str(Path(args.binary).resolve(strict=True))
    executable = ROOT / "_build/default/bench/control.exe"
    result = {
        "schema": "libtmux.control-benchmark/1", "status": "RUNNING",
        "measured_at_utc": datetime.datetime.now(datetime.UTC).isoformat(),
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": source_digest(),
        "fixture_sha256": hashlib.sha256((ROOT / "test/support/tmux_fixture.py").read_bytes()).hexdigest(),
        "executable_sha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
        "compiler": subprocess.check_output(["ocamlc", "-version"], text=True).strip(),
        "platform": {"system": platform.system(), "kernel": platform.release(),
                     "architecture": platform.machine(), "available_cpus": len(os.sched_getaffinity(0)),
                     "eio_backend_selection": os.environ.get("EIO_BACKEND", "default"),
                     "load_average_start": list(os.getloadavg())},
        "workload": {"sessions": 1, "windows": 1, "panes": 1, "clients": 1,
                     "operation": "set_option", "requests_per_sample": args.requests,
                     "concurrency": args.concurrency, "samples_per_cell": args.repeat},
        "samples": {str(value): [] for value in args.concurrency},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        for repetition in range(args.repeat):
            offset = repetition % len(args.concurrency)
            for concurrency in args.concurrency[offset:] + args.concurrency[:offset]:
                result["samples"][str(concurrency)].append(sample(binary, args.requests, concurrency))
        versions = {sample_["tmux"] for samples in result["samples"].values() for sample_ in samples}
        if len(versions) != 1:
            raise RuntimeError("tmux fixture version changed between samples")
        result["tmux"] = versions.pop()
        if source_digest() != result["source_sha256"]:
            raise RuntimeError("source changed during benchmark")
        result["summary"] = {
            key: {
                "median_requests_per_second": statistics.median(args.requests / row["seconds"] for row in samples),
                "min_requests_per_second": min(args.requests / row["seconds"] for row in samples),
                "max_requests_per_second": max(args.requests / row["seconds"] for row in samples),
                "request_latency": distribution([row["seconds"] for sample_ in samples for row in sample_["rows"]]),
                "admission_latency": distribution([row["admission_seconds"] for sample_ in samples for row in sample_["rows"]]),
                "median_loop_allocated_bytes": statistics.median(row["loop_allocated_bytes"] for row in samples),
            } for key, samples in result["samples"].items()
        }
        result["status"] = "PASS"
    except BaseException as error:
        result["status"] = "FAIL"
        result["failure"] = repr(error)
        result["failure_notes"] = getattr(error, "__notes__", [])
        raise
    finally:
        result["whole_command_seconds"] = time.perf_counter() - started
        result["platform"]["load_average_end"] = list(os.getloadavg())
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))
    print("PASS unique completed mutations, server postconditions, one persistent client and owned teardown")


if __name__ == "__main__":
    main()
