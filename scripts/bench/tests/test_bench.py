"""Tests for the benchmark drivers.

The smoke tests run each driver on the smallest workload its options allow
against the tmux binary named by LIBTMUX_TEST_TMUX (or TMUX_BINARY as a
migration alias), and check the JSON record's keys and the invariants the
driver itself asserts. Select them with `-m native`. The option checks need no
tmux.
"""

import json
import shutil
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
from support.tmux_fixture import (
    LEGACY_TEST_TMUX_ENV,
    TEST_TMUX_ENV,
    configured_test_tmux,
    resolve_test_tmux,
)

REPOSITORY = Path(__file__).resolve().parents[3]
DRIVERS = REPOSITORY / "scripts/bench"

Drive = Callable[..., dict[str, Any]]


def run(name: str, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(DRIVERS / f"{name}.py"), *arguments],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


@pytest.fixture
def drive(tmp_path: Path) -> Drive:
    """Run a driver against LIBTMUX_TEST_TMUX and return its JSON record."""
    configured = configured_test_tmux()
    if not configured:
        pytest.skip(f"set {TEST_TMUX_ENV} to a tmux release binary")
    if not shutil.which("ocamlc"):
        pytest.skip("ocamlc is not on PATH; run the tests under `opam exec --`")
    binary = resolve_test_tmux(configured)

    def drive(name: str, **options: int) -> dict[str, Any]:
        executable = REPOSITORY / f"_build/default/bench/{name}.exe"
        if not executable.is_file():
            pytest.skip(f"build the executable first: dune build bench/{name}.exe")
        output = tmp_path / f"{name}.json"
        flags = [
            argument
            for key, value in options.items()
            for argument in (f"--{key.replace('_', '-')}", str(value))
        ]
        result = run(name, *flags, "--output", str(output))
        assert result.returncode == 0, result.stdout + result.stderr
        record = json.loads(output.read_text())
        reported = subprocess.run(
            [binary, "-V"], capture_output=True, text=True, check=True
        ).stdout.strip()
        recorded = record.get("tmux") or record["versions"]["tmux"]
        assert reported.removeprefix("tmux ") == recorded.removeprefix("tmux ")
        return record

    return drive


def test_configured_test_tmux_precedence_and_fallback(tmp_path: Path) -> None:
    primary = tmp_path / "primary-tmux"
    legacy = tmp_path / "legacy-tmux"
    path_dir = tmp_path / "bin"
    path_dir.mkdir()
    on_path = path_dir / "tmux"
    for executable in (primary, legacy, on_path):
        executable.write_bytes(b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)

    env = {
        TEST_TMUX_ENV: str(primary),
        LEGACY_TEST_TMUX_ENV: str(legacy),
        "PATH": str(path_dir),
    }
    assert configured_test_tmux(env) == str(primary)
    assert resolve_test_tmux(env=env) == str(primary.resolve(strict=True))
    assert configured_test_tmux({**env, TEST_TMUX_ENV: " \t "}) == str(legacy)
    assert resolve_test_tmux(env={**env, TEST_TMUX_ENV: ""}) == str(
        legacy.resolve(strict=True)
    )
    assert (
        configured_test_tmux(
            {TEST_TMUX_ENV: " ", LEGACY_TEST_TMUX_ENV: "", "PATH": str(path_dir)}
        )
        is None
    )
    assert resolve_test_tmux(
        env={TEST_TMUX_ENV: " ", LEGACY_TEST_TMUX_ENV: "", "PATH": str(path_dir)}
    ) == str(on_path.resolve(strict=True))


@pytest.mark.parametrize(
    ("name", "arguments", "message"),
    [
        ("capture", ["--iterations", "0"], "iterations must be 1..1000"),
        ("concurrency", ["--requests", "0"], "requests must be 1..1000"),
        ("control", ["--concurrency", "33"], "concurrency must be 1..32"),
        ("mixed", ["--rounds", "7"], "rounds must be 1..6"),
        ("retention", ["--repeat", "9"], "repeat must be 1..8"),
    ],
)
def test_driver_rejects_out_of_range_options(
    name: str, arguments: list[str], message: str, tmp_path: Path
) -> None:
    for prefix in (["tmux"], []):
        result = run(name, *prefix, *arguments, "--output", str(tmp_path / "new.json"))
        assert result.returncode == 2
        assert message in result.stderr


@pytest.mark.parametrize(
    "name", ["capture", "concurrency", "control", "mixed", "retention"]
)
def test_driver_refuses_to_overwrite_its_output(name: str, tmp_path: Path) -> None:
    existing = tmp_path / "existing.json"
    existing.write_text("{}")
    result = run(name, "tmux", "--output", str(existing))
    assert result.returncode == 2
    assert "output exists; choose another file" in result.stderr
    assert existing.read_text() == "{}"


@pytest.mark.native
def test_capture(drive: Drive) -> None:
    record = drive("capture", iterations=1, repeat=1, windows=1, panes_per_window=1)
    assert record["schema"] == "libtmux.benchmark/1"
    assert record["workload"] == {
        "sessions": 1,
        "windows": 1,
        "panes": 1,
        "captures": 1,
        "selected_ids": ["%0"],
    }
    assert set(record["samples"]) == {"unix", "eio"} == set(record["summary"])
    for samples in record["samples"].values():
        [sample] = samples
        assert sample["child_processes"] == 1 and sample["observed_clients"] == 1
    assert {"head", "source_sha256", "binary_sha256", "platform"} <= set(record)


@pytest.mark.native
def test_retention(drive: Drive) -> None:
    record = drive("retention", captures=1, windows=1, repeat=1)
    assert record["schema"] == "libtmux.retention-benchmark/1"
    assert record["status"] == "PASS"
    assert record["workload"] == {
        "sessions": 1,
        "windows": 1,
        "panes": 1,
        "captures_per_sample": 1,
        "samples_per_mode": 1,
    }
    assert set(record["samples"]) == set(record["summary"])
    assert {"discard", "snapshots", "panes", "latest-pane"} <= set(record["samples"])
    for mode, samples in record["samples"].items():
        [sample] = samples
        assert sample["retained_values"] == (0 if mode == "discard" else 1)
    assert record["executable_sha256"] and record["source_sha256"]


@pytest.mark.native
def test_control(drive: Drive) -> None:
    record = drive("control", requests=1, concurrency=1, repeat=1)
    assert record["schema"] == "libtmux.control-benchmark/1"
    assert record["status"] == "PASS"
    assert record["workload"]["requests_per_sample"] == 1
    assert record["workload"]["concurrency"] == [1]
    assert set(record["samples"]) == {"1"} == set(record["summary"])
    [sample] = record["samples"]["1"]
    [row] = sample["rows"]
    assert row["name"] == "@control-bench-0000" and row["value"] == "value-0000"
    assert sample["client_process_launches"] == 1
    assert sample["helper_reaping"] == sample["owned_teardown"] == "PASS"


@pytest.mark.native
def test_concurrency(drive: Drive) -> None:
    record = drive(
        "concurrency", requests=1, concurrency=1, streams=1, cancels=1, repeat=1
    )
    assert record["schema"] == "libtmux.concurrency-benchmark/1"
    assert record["workload"] == {
        "requests": 1,
        "concurrency": 1,
        "streams": 1,
        "cancels": 1,
        "repeat": 1,
    }
    [sample] = record["samples"]
    assert [(row["index"], row["value"]) for row in sample["requests"]["rows"]] == [
        (0, "value-0")
    ]
    assert len(sample["stream_seconds"]) == len(sample["cancellation_seconds"]) == 1
    assert sample["max_clients"] == 2
    assert sample["primary_child_processes"] == 1
    assert sample["stream_child_processes"] == 2
    assert {"request_latency", "stream_latency", "cancellation_latency"} <= set(
        record["summary"]
    )


@pytest.mark.native
def test_mixed(drive: Drive) -> None:
    if not shutil.which("opam"):
        pytest.skip("mixed.py records opam package versions; opam is not on PATH")
    record = drive("mixed", rounds=1, workers=1, frames=2, payload_bytes=256)
    assert record["schema"] == "libtmux.mixed-benchmark/1"
    assert record["status"] == "PASS"
    assert record["workload"] == {
        "rounds": 1,
        "workers": 1,
        "frames_per_lane": 2,
        "payload_bytes": 256,
        "stream_lanes": 7,
        "subscribers_at_admission": 16,
        "commands_per_wave": 64,
        "queued_cancellations_per_wave": 8,
        "controller_clients": 1,
        "load_clients": 1,
    }
    result = record["sample"]["result"]
    assert len(result["attribution"]) == len(result["completion_observations"]) == 64
    assert len(result["streams"]) == 7 * 2
    [worker] = result["workers"]
    assert worker["observations"] == 64 and worker["successful"] == 64 - 8
    assert len(result["expected_gaps"]) == 1 + 7
    assert result["retained_outcomes_after_close"] is True
    cleanup = record["cleanup"]
    assert cleanup["errors"] == []
    assert cleanup["forced_cleanup_pids"] == []
    assert cleanup["remaining_direct_children"] == []
    assert cleanup["fixture_directory_removed"] is True
