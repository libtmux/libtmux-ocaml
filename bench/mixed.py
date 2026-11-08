"""Bounded mixed Eio load with source-held outcomes and owned process sampling."""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import selectors
import signal
import statistics
import subprocess
import sys
import time

from capture import ROOT, source_digest

sys.path.insert(0, str(ROOT / "test"))
from support.tmux_fixture import TmuxFixture


class InjectedFailure(RuntimeError):
    pass


def children(pid):
    result = set()
    try:
        for task in (Path("/proc") / str(pid) / "task").iterdir():
            try:
                result.update(int(value) for value in (task / "children").read_text().split())
            except FileNotFoundError:
                pass
    except FileNotFoundError:
        pass
    return result


def descendants(pid):
    result, pending = set(), list(children(pid))
    while pending:
        child = pending.pop()
        if child not in result:
            result.add(child)
            pending.extend(children(child))
    return result


def process_sample(pid):
    base = Path("/proc") / str(pid)
    try:
        stat = (base / "stat").read_text().rsplit(") ", 1)[1].split()
        status = dict(line.split(":", 1) for line in (base / "status").read_text().splitlines())
        return {"pid": pid, "start_ticks": int(stat[19]),
                "rss_bytes": int(stat[21]) * os.sysconf("SC_PAGE_SIZE"),
                "rss_high_water_bytes": int(status.get("VmHWM", "0 kB").split()[0]) * 1024,
                "fd_count": len(list((base / "fd").iterdir())),
                "cpu_seconds": (int(stat[11]) + int(stat[12])) / os.sysconf("SC_CLK_TCK")}
    except (FileNotFoundError, ProcessLookupError, PermissionError) as exc:
        return {"pid": pid, "unavailable_during_sample": type(exc).__name__}


class Ownership:
    def __init__(self):
        self.pidfds = {}

    def remember(self, pids):
        for pid in pids:
            if pid not in self.pidfds:
                try:
                    self.pidfds[pid] = os.pidfd_open(pid)
                except ProcessLookupError:
                    pass

    def verify_exit(self):
        errors, exited, reaped, forced = [], [], [], []
        for pid, descriptor in self.pidfds.items():
            try:
                with selectors.DefaultSelector() as ready:
                    ready.register(descriptor, selectors.EVENT_READ)
                    observed = bool(ready.select(1))
                    if not observed:
                        try:
                            signal.pidfd_send_signal(descriptor, signal.SIGKILL)
                            forced.append(pid)
                        except ProcessLookupError:
                            pass
                        observed = bool(ready.select(1))
                    if observed:
                        exited.append(pid)
                        try:
                            waited, _ = os.waitpid(pid, os.WNOHANG)
                            if waited:
                                reaped.append(waited)
                        except ChildProcessError:
                            pass
                    else:
                        errors.append(f"owned process {pid} has no observed exit")
            except BaseException as exc:
                errors.append(f"owned process {pid} verification: {type(exc).__name__}: {exc}")
            finally:
                try:
                    os.close(descriptor)
                except OSError as exc:
                    errors.append(f"pidfd close: {exc}")
        self.pidfds.clear()
        if forced:
            errors.append("owned processes required forced cleanup after their exit deadline")
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if not pid:
                break
            reaped.append(pid)
        remaining = sorted(children(os.getpid()))
        if remaining:
            errors.append("harness retained child processes after teardown")
        return {"verified_exited_pids": exited, "forced_cleanup_pids": forced,
                "reaped_by_harness": reaped, "remaining_direct_children": remaining,
                "errors": errors}


def sample_resources(fixture, process, ownership, event):
    command_children = descendants(process.pid)
    pane_children = descendants(fixture.server.pid)
    ownership.remember(command_children | pane_children)
    groups = {"harness": {os.getpid()}, "benchmark": {process.pid},
              "daemon": {fixture.server.pid}, "benchmark_children": command_children,
              "daemon_children": pane_children}
    clients = fixture.command("list-clients", "-F", "#{client_pid}|#{client_control_mode}|#{session_id}").stdout.decode().splitlines()
    return {"at_seconds": time.perf_counter(), "event": event,
            "attached_clients": clients,
            "groups": {name: [process_sample(pid) for pid in sorted(pids)] for name, pids in groups.items()}}


def observed_maxima(samples, *, include_clients=True):
    result = {}
    if include_clients:
        result["attached_clients"] = max(len(sample["attached_clients"]) for sample in samples)
    for name in samples[0]["groups"]:
        rows = [sample["groups"][name] for sample in samples]
        complete = [row for row in rows if all("rss_bytes" in process and "fd_count" in process for process in row)]
        result[name] = {"process_count": max(len(row) for row in rows),
                        "rss_bytes": max((sum(process["rss_bytes"] for process in row) for row in complete), default=None),
                        "fd_count": max((sum(process["fd_count"] for process in row) for row in complete), default=None),
                        "incomplete_samples": len(rows) - len(complete)}
    return result


def provenance():
    files = ["bench/mixed.ml", "bench/mixed.py", "bench/dune", "dune-project",
             ".tool-versions", "test/support/tmux_fixture.py"]
    return {"behavior_sha256": source_digest(),
            "files_sha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in files},
            "executable_sha256": hashlib.sha256((ROOT / "_build/default/bench/mixed.exe").read_bytes()).hexdigest()}


def workload(fixture, ownership, args):
    command = [str(ROOT / "_build/default/bench/mixed.exe"), fixture.binary,
               str(fixture.socket), str(args.rounds), str(args.workers),
               str(args.frames), str(args.payload_bytes), "run"]
    process = subprocess.Popen(command, cwd=ROOT, env=fixture.environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, bufsize=0)
    ownership.remember({process.pid})
    samples, progress, error, pending, result = [], [], bytearray(), bytearray(), None
    started = time.perf_counter()
    try:
        with selectors.DefaultSelector() as ready:
            ready.register(process.stdout, selectors.EVENT_READ, "stdout")
            ready.register(process.stderr, selectors.EVENT_READ, "stderr")
            while ready.get_map():
                events = ready.select(1)
                if not events:
                    raise TimeoutError("mixed workload produced no readiness/progress event within one second")
                for key, _ in events:
                    chunk = os.read(key.fd, 65_536)
                    if not chunk:
                        ready.unregister(key.fileobj)
                    elif key.data == "stderr":
                        error.extend(chunk)
                        if len(error) > 65_536:
                            raise RuntimeError("benchmark diagnostics exceeded 64 KiB")
                    else:
                        pending.extend(chunk)
                        if len(pending) > 2 * 1024 * 1024:
                            raise RuntimeError("benchmark record exceeded 2 MiB")
                        while b"\n" in pending:
                            line, _, rest = pending.partition(b"\n")
                            pending = bytearray(rest)
                            event = json.loads(line)
                            if event["event"] == "result":
                                if result is not None:
                                    raise RuntimeError("duplicate benchmark result")
                                result = event
                                continue
                            progress.append(event)
                            samples.append(sample_resources(fixture, process, ownership, event))
                            if event["event"] == "churn_created":
                                fixture.track_panes()
                                if args.inject_failure:
                                    raise InjectedFailure("intentional benchmark interruption with a live churn pane")
                            process.stdin.write(b"continue\n")
        process.wait(timeout=1)
        if process.returncode or error or pending or result is None:
            raise RuntimeError(f"benchmark exited {process.returncode}: {error.decode(errors='replace')}")
        if fixture.command("list-clients").stdout:
            raise RuntimeError("closed native clients remain attached")
        if children(process.pid):
            raise RuntimeError("native process left direct children")
        return {"seconds": time.perf_counter() - started, "result": result,
                "progress": progress, "resource_samples": samples,
                "observed_sample_maxima": observed_maxima(samples),
                "native_event_sample_maxima": observed_maxima([{ "attached_clients": [], "groups": row["occurrence_resources"]} for row in progress if row.get("occurrence_resources") is not None], include_clients=False)}
    except BaseException as exc:
        evidence = {"seconds": time.perf_counter() - started,
                    "progress": progress, "resource_samples": samples,
                    "stderr": error.decode(errors="replace"),
                    "failed_progress_index": len(progress) - 1 if progress else None,
                    "observer_command": list(exc.cmd) if isinstance(exc, subprocess.CalledProcessError) else None,
                    "observer_returncode": exc.returncode if isinstance(exc, subprocess.CalledProcessError) else None,
                    "observer_stdout": getattr(exc, "stdout", b"").decode(errors="replace") if isinstance(getattr(exc, "stdout", b""), bytes) else getattr(exc, "stdout", None),
                    "observer_command_stderr": getattr(exc, "stderr", b"").decode(errors="replace") if isinstance(getattr(exc, "stderr", b""), bytes) else getattr(exc, "stderr", None),
                    "probe_errors": []}
        exc.benchmark_evidence = evidence
        for name, probe in [
            ("observed_sample_maxima", lambda: observed_maxima(samples) if samples else {}),
            ("benchmark_returncode", process.poll),
            ("daemon_returncode_before_native_cleanup", fixture.server.poll),
        ]:
            evidence[name] = None
            try:
                evidence[name] = probe()
            except Exception as probe_error:
                evidence["probe_errors"].append({"probe": name, "error": f"{type(probe_error).__name__}: {probe_error}"})
        evidence["daemon_pidfd_ready_before_native_cleanup"] = None
        try:
            if fixture.pidfd is not None:
                with selectors.DefaultSelector() as ready:
                    ready.register(fixture.pidfd, selectors.EVENT_READ)
                    evidence["daemon_pidfd_ready_before_native_cleanup"] = bool(ready.select(0))
        except Exception as probe_error:
            evidence["probe_errors"].append({"probe": "daemon_pidfd", "error": f"{type(probe_error).__name__}: {probe_error}"})
        raise
    finally:
        cleanup_errors = []
        try:
            ownership.remember(descendants(process.pid))
            if process.poll() is None:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
            process.wait(timeout=1)
        except BaseException as exc:
            cleanup_errors.append(f"native process cleanup: {type(exc).__name__}: {exc}")
        for stream in (process.stdin, process.stdout, process.stderr):
            try:
                stream.close()
            except BaseException as exc:
                cleanup_errors.append(f"native pipe cleanup: {type(exc).__name__}: {exc}")
        if cleanup_errors:
            active = sys.exception()
            if active is not None:
                active.benchmark_cleanup_errors = cleanup_errors
            else:
                exc = RuntimeError("; ".join(cleanup_errors))
                exc.benchmark_evidence = {"progress": progress, "resource_samples": samples}
                raise exc


def validate(sample, args):
    result = sample["result"]
    completions = result["completion_observations"]
    if len(completions) != args.rounds * 64:
        raise RuntimeError("missing command completion observations")
    if [row["completion_observation"] for row in completions] != list(range(args.rounds * 64)):
        raise RuntimeError("completion observation order differs")
    identities = {(row["round"], row["index"]) for row in completions}
    if identities != {(round_, index) for round_ in range(args.rounds) for index in range(64)}:
        raise RuntimeError("duplicate or unattributed command outcome")
    if len({row["operation"] for row in completions}) != len(completions):
        raise RuntimeError("retained operation identities are not unique")
    if sum(row["cancelled_before_write"] for row in completions) != args.rounds * 8:
        raise RuntimeError("queued cancellation count differs")
    stream_ids = [(row["round"], row["lane"], row["frame"]) for row in result["streams"]]
    expected = {(round_, lane, frame) for round_ in range(args.rounds) for lane in range(7) for frame in range(args.frames)}
    if len(stream_ids) != len(expected) or set(stream_ids) != expected:
        raise RuntimeError("stream attribution or frame count differs")
    if len(result["cancellations"]) != args.rounds:
        raise RuntimeError("missing retained cancellation outcomes")
    overlap = [row for row in sample["progress"] if row["event"] in {"stream_observed", "churn_created", "retained_cancelled"} and row["occurrence"]["commands_pending"] > 0]
    for round_ in range(args.rounds):
        for event in ("stream_observed", "churn_created", "retained_cancelled"):
            if not any(row["round"] == round_ and row["event"] == event for row in overlap):
                raise RuntimeError(f"round {round_} did not demonstrate command overlap with {event}")
    if sample["observed_sample_maxima"]["attached_clients"] < 9:
        raise RuntimeError("near-limit stream topology was not observed")
    if len(result["attribution"]) != len(completions) or any(row["expected"] != row["observed"] for row in result["attribution"]):
        raise RuntimeError("raw request attribution differs")
    verified = [row for row in sample["progress"] if row["event"] == "option_verified"]
    if ([row["verified"] for row in verified] != list(range(1, len(completions) + 1))
            or any(row["total"] != len(completions) for row in verified)
            or [row["operation"] for row in verified] != [row["operation"] for row in result["attribution"]]):
        raise RuntimeError("option verification progress differs from attributed requests")
    worker_rows = []
    for worker in range(args.workers):
        rows = [row for row in completions if row["worker"] == worker]
        expected = args.rounds * sum(index % args.workers == worker for index in range(64))
        if len(rows) != expected:
            raise RuntimeError("a worker did not finish its bounded request quota")
        worker_rows.append({"worker": worker, "observations": len(rows),
                            "successful": sum(not row["cancelled_before_write"] for row in rows),
                            "cancelled_before_write": sum(row["cancelled_before_write"] for row in rows),
                            "first_observed_seconds": min(row["observed_at_seconds"] for row in rows),
                            "last_observed_seconds": max(row["observed_at_seconds"] for row in rows),
                            "median_observation_latency_seconds": statistics.median(row["seconds"] for row in rows),
                            "max_observation_latency_seconds": max(row["seconds"] for row in rows)})
    return {"overlapping_progress_observations": len(overlap),
            "per_worker": worker_rows,
            "worker_last_observation_spread_seconds": max(row["last_observed_seconds"] for row in worker_rows) - min(row["last_observed_seconds"] for row in worker_rows),
            "command_observation_latency_seconds": {"min": min(row["seconds"] for row in completions),
              "median": statistics.median(row["seconds"] for row in completions),
              "max": max(row["seconds"] for row in completions)}}


def core_diagnostics(fixture, args):
    if fixture.server is None or fixture.server.poll() is None:
        return {"core_present": None, "status": "daemon_exit_not_observed"}
    uses_pid = Path("/proc/sys/kernel/core_uses_pid").read_text().strip()
    if uses_pid not in {"0", "1"}:
        raise RuntimeError("unrecognized process-local core suffix policy")
    filename = f"core.{fixture.server.pid}" if uses_pid == "1" else "core"
    core = fixture.socket.parent / filename
    if not core.exists():
        return {"core_present": False}
    args.diagnostics_dir.mkdir(parents=True, exist_ok=True)
    saved = args.diagnostics_dir / "daemon.core"
    if saved.exists():
        raise FileExistsError("diagnostic core already exists")
    shutil.copyfile(core, saved)
    command = ["gdb", "--batch", "--nx", "-iex", "set auto-load safe-path /nonexistent",
               "-ex", "set pagination off", "-ex", "thread apply all bt 30", "-ex", "info registers",
               fixture.binary, str(saved)]
    record = {"core_present": True, "core_bytes": saved.stat().st_size,
              "core_sha256": hashlib.sha256(saved.read_bytes()).hexdigest(),
              "command": [item.replace(str(ROOT), "<repo>").replace(str(args.diagnostics_dir), "<diagnostics>") for item in command]}
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=1,
                                env={**os.environ, "DEBUGINFOD_URLS": ""})
        record.update(returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    except subprocess.TimeoutExpired as exc:
        record.update(timed_out=True, stdout=(exc.stdout or b"").decode(errors="replace"),
                      stderr=(exc.stderr or b"").decode(errors="replace"))
    return record


def main():
    started = time.perf_counter()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--frames", type=int, default=4)
    parser.add_argument("--payload-bytes", type=int, default=256)
    parser.add_argument("--inject-failure", action="store_true")
    parser.add_argument("--core-diagnostics", action="store_true")
    parser.add_argument("--diagnostics-dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for name, low, high in [("rounds", 1, 6), ("workers", 1, 16), ("frames", 2, 12), ("payload_bytes", 256, 2048)]:
        if not low <= getattr(args, name) <= high:
            parser.error(f"{name} must be {low}..{high}")
    if args.core_diagnostics:
        if Path("/proc/sys/kernel/core_pattern").read_text().strip() != "core":
            parser.error("core diagnostics require an unchanged process-local core filename")
        if args.diagnostics_dir is None or args.diagnostics_dir.exists():
            parser.error("core diagnostics require a new --diagnostics-dir")
    if args.output.exists():
        parser.error("output exists; choose another file")
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")
    ownership, before, failure, sample, cleanup = Ownership(), provenance(), None, None, None
    fixture = TmuxFixture(args.binary)
    result = {"schema": "libtmux.mixed-benchmark/1", "status": "FAIL",
              "measured_at_utc": datetime.datetime.now(datetime.UTC).isoformat(),
              "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "dirty_paths": subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).splitlines(),
              "source_before": before,
              "versions": {name: subprocess.check_output(command, text=True).strip() for name, command in {
                  "ocaml": ["ocamlc", "-version"], "dune": ["dune", "--version"],
                  "python": [sys.executable, "--version"], "tmux": [fixture.binary, "-V"],
                  "dependencies": ["opam", "list", "--installed", "--columns=name,version", "--short", "eio", "eio_main", "mtime", "yojson"]}.items()},
              "environment": {"TMUX": "removed", "TMUX_PANE": "removed",
                              "LANG": os.environ.get("LANG"), "LC_ALL": os.environ.get("LC_ALL"),
                              "OCAMLRUNPARAM": os.environ.get("OCAMLRUNPARAM"),
                              "build_profile": "Dune dev", "opam_root": "scratch/opam-root"},
              "tmux_binary_sha256": hashlib.sha256(Path(fixture.binary).read_bytes()).hexdigest(),
              "tmux_fixture_provenance": json.loads((ROOT / "scratch/tmux" / (Path(fixture.binary).parent.name.removeprefix("tmux-") + ".json")).read_text()),
              "platform": {"kernel": platform.release(), "architecture": platform.machine(),
                           "cpu_affinity": sorted(os.sched_getaffinity(0)), "load_average_start": os.getloadavg()},
              "command": ["python3", "bench/mixed.py", f"scratch/tmux/{Path(fixture.binary).parent.name}/tmux",
                          "--rounds", str(args.rounds), "--workers", str(args.workers), "--frames", str(args.frames),
                          "--payload-bytes", str(args.payload_bytes), *( ["--inject-failure"] if args.inject_failure else []),
                          *( ["--core-diagnostics", "--diagnostics-dir", "<new-diagnostics-dir>"] if args.core_diagnostics else []),
                          "--output", "<new-output.json>"],
              "workload": {"rounds": args.rounds, "workers": args.workers, "frames_per_lane": args.frames,
                           "payload_bytes": args.payload_bytes, "stream_lanes": 7, "subscribers_at_admission": 16,
                           "commands_per_wave": 64, "queued_cancellations_per_wave": 8,
                           "controller_clients": 1, "load_clients": 1},
              "route": "set-option via retained control connection; verification read_option via temporary subprocess",
              "resource_method": "event-acknowledged /proc and list-clients samples; observed maxima, not continuous peaks"}
    try:
        if args.core_diagnostics:
            previous_limit = resource.getrlimit(resource.RLIMIT_CORE)
            bound = 64 * 1024 * 1024
            if previous_limit[1] != resource.RLIM_INFINITY:
                bound = min(bound, previous_limit[1])
            if bound == 0:
                raise RuntimeError("process-local core hard limit forbids diagnostics")
            resource.setrlimit(resource.RLIMIT_CORE, (bound, previous_limit[1]))
            previous_directory = Path.cwd()
            try:
                os.chdir(fixture.directory.name)
                fixture.__enter__()
            finally:
                os.chdir(previous_directory)
                resource.setrlimit(resource.RLIMIT_CORE, previous_limit)
            if not os.path.samefile(f"/proc/{fixture.server.pid}/cwd", fixture.directory.name):
                raise RuntimeError("daemon core directory is not owned by this fixture")
        else:
            fixture.__enter__()
        ownership.remember({fixture.server.pid})
        for index in range(8):
            marker = fixture.socket.parent / f"ready-{index}"
            marker.write_text(f"mixed ready {index}\n")
            command = ('stty -echo; exec /bin/cat -u "$1" -', "mixed-producer", str(marker))
            if index == 0:
                fixture.command("rename-session", "-t", "$0", "mixed-0")
                fixture.command("respawn-pane", "-k", "-t", "%0", "/bin/sh", "-c", *command)
            else:
                fixture.command("new-session", "-d", "-s", f"mixed-{index}", "/bin/sh", "-c", *command)
        fixture.track_panes()
        ownership.remember(descendants(fixture.server.pid))
        sample = workload(fixture, ownership, args)
        result["summary"] = validate(sample, args)
        result["status"] = "PASS"
    except BaseException as exc:
        failure = exc
        sample = getattr(exc, "benchmark_evidence", sample)
        result["error"] = f"{type(exc).__name__}: {exc}".replace(str(fixture.socket.parent), "<fixture>").replace(str(ROOT), "<repo>")
        result["daemon_observation_phase"] = "after_native_cleanup"
        result["daemon_returncode_before_cleanup"] = None
        try:
            if fixture.server is not None:
                result["daemon_returncode_before_cleanup"] = fixture.server.poll()
        except Exception as probe_error:
            result["daemon_poll_error"] = f"{type(probe_error).__name__}: {probe_error}"
        if not fixture.log.closed:
            try:
                fixture.log.seek(0)
                result["daemon_log"] = fixture.log.read(65_536).decode(errors="replace")
            except OSError as log_error:
                result["daemon_log_error"] = str(log_error)
        result["failure_kind"] = "daemon_signal" if (result["daemon_returncode_before_cleanup"] or 0) < 0 else "workload_or_observer_failure"
        result["workload_cleanup_errors"] = getattr(exc, "benchmark_cleanup_errors", [])
        if args.core_diagnostics:
            try:
                result["core_diagnostics"] = core_diagnostics(fixture, args)
            except BaseException as diagnostic_error:
                result["core_diagnostics_error"] = f"{type(diagnostic_error).__name__}: {diagnostic_error}"
        if isinstance(exc, InjectedFailure) and args.inject_failure:
            result["status"] = "EXPECTED_FAILURE"
    finally:
        try:
            fixture.close()
        except BaseException as exc:
            result["fixture_cleanup_error"] = f"{type(exc).__name__}: {exc}"
            result["status"] = "FAIL"
        cleanup = ownership.verify_exit()
        cleanup["fixture_directory_removed"] = not Path(fixture.directory.name).exists()
        if cleanup["errors"] or not cleanup["fixture_directory_removed"]:
            result["status"] = "FAIL"
        result.update(sample=sample, cleanup=cleanup, whole_command_seconds=time.perf_counter() - started)
        try:
            result["source_after"] = provenance()
        except BaseException as exc:
            result["source_after"] = None
            result["provenance_error"] = f"{type(exc).__name__}: {exc}"
            result["status"] = "FAIL"
        if result.get("workload_cleanup_errors"):
            result["status"] = "FAIL"
        if result["source_before"] != result["source_after"]:
            result["status"] = "FAIL"
            result["source_changed_during_run"] = True
        args.output.parent.mkdir(parents=True, exist_ok=True)
        serialized = json.dumps(result, indent=2).replace(str(fixture.socket.parent), "<fixture>").replace(str(ROOT), "<repo>")
        if args.diagnostics_dir is not None:
            serialized = serialized.replace(str(args.diagnostics_dir), "<diagnostics>")
        args.output.write_text(serialized + "\n")
    print(json.dumps({"status": result["status"], "summary": result.get("summary"),
                      "seconds": result["whole_command_seconds"], "error": result.get("error")}, indent=2))
    if result["status"] == "FAIL":
        raise SystemExit(1)
    if failure is not None and result["status"] != "EXPECTED_FAILURE":
        raise failure


if __name__ == "__main__":
    main()
