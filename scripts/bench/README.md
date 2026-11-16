# bench

Python drivers for the OCaml benchmarks in `bench/`. Each driver starts an
owned tmux fixture, runs the matching executable
`_build/default/bench/<name>.exe` against it, checks what the executable
reports, and writes one JSON record with timings, hashes and host details. The
OCaml sources and `bench/dune` stay in `bench/`; recorded results stay in
`bench/results/`.

- `capture.py` compares serial blocking and Eio graph capture. It also holds
  `ROOT` and `source_digest()`, which the other drivers import.
- `retention.py` measures live OCaml heap retained by captured graphs.
- `control.py` measures typed option writes through one persistent Eio control
  client.
- `concurrency.py` measures bounded concurrent reads, streaming and
  cancellation.
- `mixed.py` overlaps commands, stream pressure and membership changes.

[Benchmarks](../../docs/benchmarking.md) describes each workload, the
recorded results and how to read them.

## Who runs it

Maintainers run the drivers by hand when they change the runtime, and keep each
run under ten minutes. CI does not run the measurements. The native job runs a
smoke test for each driver, on the smallest workload its options allow, with
`pytest -m native` against each tmux release binary.

## Run

Build the executable, then run the driver on an exact tmux release binary
with a new output path:

```console
$ opam exec -- dune build bench/capture.exe
```

```console
$ opam exec -- uv run scripts/bench/capture.py /path/to/tmux-3.8/bin/tmux \
    --output scratch/capture.json
```

The docs page lists the options for each driver. A driver refuses an existing
output file.

Run the smoke tests. They skip when `TMUX_BINARY` is unset or an executable is
not built. Build all five first:

```console
$ opam exec -- dune build \
    bench/capture.exe \
    bench/concurrency.exe \
    bench/control.exe \
    bench/mixed.exe \
    bench/retention.exe
```

```console
$ TMUX_BINARY=/path/to/tmux-3.8/bin/tmux \
    opam exec -- uv run pytest -m native scripts/bench
```
