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

## Heap retained across captures

Keeping one pane keeps its captured graph reachable. The
[retention benchmark](../bench/retention.py) measures this with a blocking
client and one session containing one pane per window. Each sample runs in a
fresh process, warms the connection, then captures the same graph 100 times.
It measures live OCaml heap after full major collection before capture, while
retained values remain reachable, and after releasing them.

On OCaml 5.5.2 and tmux 3.8, six samples per mode produced these live-heap
increases in KiB. Every sample had the same retained-byte count:

| Windows | Every snapshot | One pane per capture | Latest pane only | Evidence |
| --- | --- | --- | --- | --- |
| 1 | 115.6 | 117.9 | 1.1 | [Raw data](../bench/results/retention-3.8-1x1.json) |
| 16 | 982.8 | 985.1 | 9.8 | [Raw data](../bench/results/retention-3.8-16x1.json) |
| 64 | 3757.8 | 3760.1 | 37.6 | [Raw data](../bench/results/retention-3.8-64x1.json) |

Retaining 100 detached `(id, command, path)` summaries used 13.2 KiB in each
graph shape; 100 `Pane.target` values used 6.2 KiB. With 64 windows and
[25 captures](../bench/results/retention-3.8-64x1-25-captures.json), retaining
one pane per capture used 940.0 KiB, while retaining only the latest pane
still used 37.6 KiB. Targets remain connection-bound; retaining one does not
authorize a future connection.

These are total live-heap differences, including list cells and projected
values, not exact arena sizes. The discard control and every release phase
returned 40 bytes below the warm baseline, a small baseline-overhead offset.
This measurement does not cover process RSS, tmux memory, relationship-array
allocation or a general leak guarantee. Mode order rotates across samples.
The harness verifies topology, retained value counts, detached clients and
owned daemon/pane teardown. Sample durations include the client-exit check;
whole-command duration includes fixture setup and teardown.

Build the benchmark:

```console
$ opam exec -- dune build bench/retention.exe
```

Run the 64-window case with a new output path:

```console
$ opam exec -- python3 bench/retention.py scratch/tmux/tmux-3.8/tmux \
    --windows 64 \
    --captures 100 \
    --repeat 6 \
    --output scratch/retention.json
```

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

## Mixed commands, stream pressure and membership changes

The [mixed-load benchmark](../bench/mixed.py) overlaps retained command
submissions, seven fast stream readers, seven deliberately stalled readers,
membership changes and cancellation. Its default runs three waves with eight
command workers and four attributed output frames per stream lane. It adds no
work to the unit-test loops.

Build the executable separately:

```console
$ opam exec -- dune build bench/mixed.exe
```

Run the bounded workload against one owned release fixture:

```console
$ opam exec -- python3 bench/mixed.py scratch/tmux/tmux-3.8/tmux \
    --output scratch/mixed-baseline.json
```

Each wave submits 64 commands without yielding and requires the 65th to reject
with the declared admission limit. Eight queued operations are cancelled before
writing; their handles retain `Not_started`. Sixteen subscribers occupy seven
shared session lanes. Together with the load connection's primary lane this
reaches its eight-lane limit; a separate controller connection sends output and
changes membership. The seventeenth subscriber and an additional session lane
must reject with their specific capacity errors. These expected rejections are
recorded separately from correctness failures.

Commands set unique user-option names and values. The receipt retains operation
IDs, worker IDs, submission indexes and the actual order in which awaiters
observe results. It verifies every resulting option value, including absence
for cancelled operations. Ordinary mutations use the retained control lane;
`read_option` verification runs afterward through its temporary subprocess route
and has a separate phase duration. Each verified option emits its operation ID,
completed count and read duration before the observer handshake. The validation
phase includes those handshakes; individual read durations exclude them.
The observer acknowledgements and resource queries add measured overhead, so
these are instrumented workload timings.

Fast streams must deliver exact ordered bytes with continuous generation and
byte offsets. Tiny unconsumed queues must report `Gap Overflow`, then `End`.
Splitting and removing a temporary pane changes a watched window's membership;
affected readers must report `Gap Membership_changed`, then `End`. Explicit
readmission uses a fresh observation and generation. Unchanged lanes continue independently; the receipt requires observed stream
progress while commands remain pending in each wave. Each wave also cancels an active observer after
its retained wait reaches `Acknowledged`, releases the wait through the
controller, and checks the eventual result before and after client closure.

Native event callbacks synchronously sample owned Linux process trees before
yielding to telemetry, retaining their occurrence-time pending-command counts.
Progress handshakes separately sample process trees and attached tmux clients,
including while the churn pane is alive. Emission timestamps and counts stay
separate from event occurrence; queued telemetry cannot manufacture overlap. Raw records distinguish
the Python harness, OCaml process, daemon, command-client children and pane
children. RSS/FD/process/client maxima are maxima of these observations;
per-process RSS high-water marks come from the kernel. They do not establish
continuous aggregate resource peaks. The controller contributes a primary client
and, during its retained wait, an auxiliary client in addition to the load
connection's eight clients. The sampler's own retained pidfds affect its FD count.

Per-worker receipts report completed quotas, cancellation counts, latency samples
and first/last observation times. They characterize this bounded workload rather
than proving scheduler fairness, a service-level objective or general capacity.
The 1 MiB queued-byte and 32 MiB payload limits are recorded source constraints;
this workload pressures admission counts, subscriber counts and lane counts,
not those byte maxima. No automatic retries or timeout increases hide a failure.

Exercise teardown after interruption with a new output file:

```console
$ opam exec -- python3 bench/mixed.py scratch/tmux/tmux-3.8/tmux \
    --rounds 1 \
    --frames 2 \
    --inject-failure \
    --output scratch/mixed-interrupted.json
```

`EXPECTED_FAILURE` means the harness intentionally interrupted the native
process while a temporary pane was alive. It still requires owned daemon,
pane and command-client exit, reaping, zero remaining children and removal of
the private fixture directory. Unexpected errors or failed cleanup produce
`FAIL`; an interruption is not a successful workload measurement.

The [summary](../bench/results/mixed-20261108.json) records each outcome and
source identity. The linked gzip archives contain the complete JSON receipts;
the summary includes their compressed and uncompressed SHA-256 digests.

Raw results retain exact source and executable hashes, fixture-helper hash,
versions, command arguments, workload bounds, host load, resource observations
and cleanup receipts. Keep failed receipts beside passing measurements when
assessing a release. Current collector qualification is **PARTIAL** across the supported releases:

| tmux | Mixed workload disposition | Raw evidence |
| --- | --- | --- |
| 3.3 | Current workload passed; an earlier observer-command failure remains unattributed. | [Current](../bench/results/mixed-3.3-current-20261108.json.gz), [earlier failure](../bench/results/mixed-3.3-qualified-20261108.json.gz) |
| 3.3a | Current workload passed. | [Current](../bench/results/mixed-3.3a-current-20261108.json.gz) |
| 3.4 | Reproduced daemon SIGSEGV: a null control state is dereferenced while notifying control clients of a detach. | [Failure](../bench/results/mixed-3.4-qualified-20261108.json.gz), [core analysis](../bench/results/mixed-3.4-crash-analysis-20261108.json) |
| 3.8 | Current default workload and intentional interruption cleanup passed. | [Default](../bench/results/mixed-3.8-current-20261108.json.gz), [interruption](../bench/results/mixed-3.8-current-interrupted-20261108.json.gz) |

Earlier records predate collector corrections; use their recorded source hashes.
A later passing sample does not resolve an unexplained failure. These outcomes
qualify this mixed benchmark separately from the existing native runtime tests.

The three 3.4 cores identify the same upstream write path. A later
[tmux correction](https://github.com/tmux/tmux/commit/93169e2e6231853c61c33432bceebf4ffc91015b)
guards null control state; that guard is present in the exact 3.8 source.
The precise triggering sequence remains unproved. The supported range is
3.3a–3.8; the 3.3 measurements above are historical evidence. The 3.4 mixed
workload remains a failed qualification.

Benchmarks are a separate tier. Correctness gates and test-loop timings are
listed in [testing](testing.md), not used as throughput measurements. Keep a
single benchmark run under ten minutes and a complete sweep under one hour.

[Compatibility](compatibility.md) · [Control](control.md) · [Guide](README.md)
