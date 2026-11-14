# Current capabilities and adoption gaps

- The model, typed queries, native Linux clients, output observation and
  workspace CLI are tested against real tmux 3.3a and 3.8. Releases in between
  are supported but not run in CI.
- The [guide and API reference](https://libtmux.org/en/ocaml/) are hosted.
- Not on opam yet. The final suite review is unfinished.

## What an application can use

- Capture a graph, keep it after closing the client, and walk shared windows
  through session links.
- Filter with native predicates or typed expressions; check cardinality before
  a mutation.
- Run native operations on sessions, windows, panes, clients, layouts,
  environment, options and hooks.
- Keep operation outcomes and watch bounded subscriptions from the blocking or
  Eio client.

The [compatibility table](compatibility.md) lists qualified components; the
[examples](README.md) run against servers they own.

## What is still missing

| Area | Required evidence before complete-suite adoption |
| --- | --- |
| Documentation site | Qualify the final hosted reference and verify its deployed links; public `.cmti` export and local rendering are implemented |
| Known runtime findings | Account for the [recorded daemon-exit and observer failures](compatibility.md) when choosing a deployment workload |
| Final qualification | Rerun every required component and exact release cell on the final source revision |
| Package adoption | Obtain an independent caller-task review and resolve material findings |

[Recorded benchmarks](benchmarking.md) cover capture, concurrency, memory, CPU,
output latency and cancellation cleanup.

The workspace model, JSON loader, blocking and Eio executors and the CLI are
implemented; the [workspace guide](workspaces.md) walks through them.

- Live tests cover partial effects, compensation, append isolation, stale
  plans, cancellation journals and bootstrap on fresh and existing daemons.
- Cleanup removes only panes whose creation is proven. Foreign panes moved into
  a new window remain.
- Plans and receipts record errors, creation IDs and cleanup outcomes. They are
  output, not input to replay.

## Engineering assessment

- For a Linux application that needs immutable tmux observations and explicit
  native control, the model and clients are candidates for adoption within the
  documented limits. Suite adoption needs the gates above.
- Expect explicit endpoints, client lifetimes, command uncertainty and stream
  gaps. The API keeps them visible and never reconnects for you.
- The supported surfaces are the native OCaml APIs and the workspace CLI; see
  [package boundaries](packages.md) and [testing](testing.md).
