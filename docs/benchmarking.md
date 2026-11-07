# Measure graph capture on the same workload

The [capture benchmark](../bench/capture.py) compares serial blocking and Eio
capture on one owned graph: one session, four windows and sixteen panes. Each
sample captures the graph 100 times and selects active panes using both a
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
per-sample process time and CPU usage. Samples include program startup, binding,
the capture loop and client closure. Fixture creation and compilation are
outside the per-sample interval. Mode order alternates across repetitions.

## Interpret the samples

Compare modes on the same graph, exact compiler and tmux release. Read the raw
sample range and host load alongside each median. A serial capture workload
exercises capture and query agreement; concurrent saturation, large graph
scaling, allocation profiling and streaming cancellation latency need separate
workloads.

Benchmarks are a separate tier. Correctness gates and test-loop timings are
listed in [testing](testing.md), not used as throughput measurements. Keep a
single benchmark run under ten minutes and a complete sweep under one hour.

[Compatibility](compatibility.md) · [Control](control.md) · [Guide](README.md)
