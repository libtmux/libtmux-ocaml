# Measure capture, concurrency and output delivery

The [capture benchmark](../bench/capture.py) compares serial blocking and Eio
capture on one owned graph: one session, four windows and sixteen panes. Each
sample captures the graph 100 times by default and selects active panes using both a
compiled expression and a native predicate over each same snapshot.

The harness checks exact ordered IDs across captures and modes, one observed
tmux client and one child process per mode, and zero attached clients afterward.
Owned fixture teardown verifies pane and daemon exit. Both modes reuse one
bound connection for their captures; they perform no per-object acquisition.

## Reproduce

Prepare the [exact release fixture](../.github/CONTRIBUTING.md#owned-tmux-fixtures),
then build the benchmark outside normal test loops:

```console
$ opam exec -- dune build bench/capture.exe
```

Run it with Python 3.11 or newer. Choose a new output file each time:

```console
$ opam exec -- python3 bench/capture.py scratch/tmux/tmux-3.8/tmux \
    --iterations 100 \
    --repeat 5 \
    --output scratch/capture-baseline.json
```

The output records compiler and tmux versions, binary and behavior-source hashes,
OS/architecture, CPU availability, starting load average, whole-command time,
per-sample process time, client and daemon CPU usage, and OCaml heap allocation
during the capture loop. Samples include program startup, binding,
the capture loop and client closure. Fixture creation and compilation are
outside the per-sample interval. Mode order alternates across repetitions.

## Capture and graph size

These observations use OCaml 5.5.2 on one shared Linux host. Each table entry is
median milliseconds for 50 captures, followed by its min–max across three
samples. The raw files retain the source commit, behavior hash and host load.

| tmux | Blocking, ms | Eio, ms | Evidence |
| --- | --- | --- | --- |
| 3.3 | 49.7 (49.0–52.6) | 54.6 (53.9–55.2) | [Raw data](../bench/results/capture-3.3-4x4.json) |
| 3.3a | 76.3 (76.3–76.3) | 86.6 (72.1–90.1) | [Raw data](../bench/results/capture-3.3a-4x4.json) |
| 3.4 | 74.1 (72.6–76.0) | 75.8 (61.8–76.9) | [Raw data](../bench/results/capture-3.4-4x4.json) |
| 3.8 | 52.0 (48.7–66.6) | 67.1 (52.4–69.0) | [Raw data](../bench/results/capture-3.8-4x4.json) |

Change `--windows` and `--panes-per-window` to measure larger graphs. The same
tmux 3.8 workload, with 50 captures and three samples per mode, produced:

| Windows × panes per window | Blocking median, ms | Eio median, ms | Evidence |
| --- | --- | --- | --- |
| 1 × 1 | 28.5 | 28.0 | [Raw data](../bench/results/capture-3.8-1x1.json) |
| 4 × 4 | 52.0 | 67.1 | [Raw data](../bench/results/capture-3.8-4x4.json) |
| 8 × 8 | 113.8 | 114.9 | [Raw data](../bench/results/capture-3.8-8x8.json) |
| 16 × 16 | 402.2 | 408.5 | [Raw data](../bench/results/capture-3.8-16x16.json) |

The largest graph has 256 panes. Each observation still uses batched graph
acquisition. Allocation counters cover the OCaml heap during the capture loop;
they do not measure process RSS or tmux's allocations.

## Concurrent requests, streaming and cancellation

The [Eio benchmark](../bench/concurrency.py) runs bounded concurrent option
reads with distinct expected values. It checks response attribution and input
order, then measures future output from an owned `cat` process with terminal
echo disabled. Output cursors must advance. Finally it cancels active byte
waits and checks subscription cleanup. One primary client becomes two while a
stream lane is active; both observed client and child-process counts are
checked. No clients remain after closure, and owned pane/daemon exit is verified.

Build the executable outside normal test loops:

```console
$ opam exec -- dune build bench/concurrency.exe
```

Run the three phases against an owned release fixture:

```console
$ opam exec -- python3 bench/concurrency.py scratch/tmux/tmux-3.8/tmux \
    --requests 128 \
    --concurrency 8 \
    --streams 10 \
    --cancels 10 \
    --repeat 3 \
    --output scratch/concurrency-baseline.json
```

Request time includes queueing until the attributed response. Stream time runs
from sending literal input through observing the process's output. Cancellation
time runs from the cancellation request through the observer receiving it,
including subscription cleanup. The p95 uses nearest rank across all samples.

On tmux 3.8, each row contains 384 requests, 30 stream samples and 30 cancellations:

| Concurrent requests | Median requests/s | Request p95, ms | Stream p95, ms | Cancel p95, ms | Evidence |
| --- | --- | --- | --- | --- | --- |
| 1 | 556.6 | 2.517 | 0.598 | 0.258 | [Raw data](../bench/results/concurrency-3.8-c1.json) |
| 8 | 487.9 | 19.955 | 0.863 | 0.368 | [Raw data](../bench/results/concurrency-3.8-c8.json) |
| 16 | 561.5 | 29.746 | 0.569 | 0.220 | [Raw data](../bench/results/concurrency-3.8-c16.json) |
| 64 | 423.5 | 159.039 | 0.667 | 0.406 | [Raw data](../bench/results/concurrency-3.8-c64.json) |

The eight-request workload also passes on
[3.3](../bench/results/concurrency-3.3-c8.json),
[3.3a](../bench/results/concurrency-3.3a-c8.json) and
[3.4](../bench/results/concurrency-3.4-c8.json).
Higher concurrency increases queueing on the retained connection. These
measurements come from a shared host running other work; compare raw sample
ranges and load before choosing a workload or drawing performance conclusions.

Benchmarks are a separate tier. Correctness gates and test-loop timings are
listed in [testing](testing.md), not used as throughput measurements. Keep a
single benchmark run under ten minutes and a complete sweep under one hour.

[Compatibility](compatibility.md) · [Control](control.md) · [Guide](README.md)
