# Use libtmux from OCaml

Start with an explicit tmux endpoint. Capture immutable observations, inspect
and filter them locally, then perform an explicit action with a bound target.

| Task | Guide | Executed program |
| --- | --- | --- |
| Install and connect | [First use](getting-started.md) | [Capture](../examples/native_capture.ml) |
| Choose libraries and optional runtimes | [Packages](packages.md) | [Authored manifests](../libtmux.opam) |
| Run one self-contained capability program | [Standalone examples](showcases.md) | [Executed inventory](../examples/showcase.json) |
| Understand sessions, shared windows and panes | [Object graph](graph.md) | [Inspect graph](../examples/native_graph.ml) |
| Native predicates, typed queries and cardinality | [Queries](queries.md) | [Query snapshot](../examples/native_query.ml) |
| Create layouts, set options and handle outcomes | [Control and recovery](control.md) | [Build layout](../examples/native_build.ml) |
| Cancel a waiter and recover its operation | [Recovery walkthrough](recovery.md) | [Retained outcome](../examples/native_recovery.ml) |
| Concurrent literal send and output observation | [Streaming](streaming.md) | [Eio send and observe](../examples/native_watch.ml) |
| Wait for text already on screen | [Rendered waits](streaming.md) | [Wait](../examples/native_wait.ml) |
| Validate, preview and apply a JSON workspace | [Workspaces](workspaces.md) | [Project configuration](../examples/workspace/project.json) |
| Compare measured capture workloads | [Benchmarks](benchmarking.md) | [Capture harness](../bench/capture.py) |
| Browse modules and signatures | [API documentation](api.md) | Public `.mli` sources |
| Review package-wide design choices | [Architecture decisions](dev/adr/README.md) | [Implemented architecture](dev/adr/0001-native-ocaml-suite.md) |

The field, option and format references are generated from the same catalogs as
the library: [fields](fields.md), [options](options.md), [formats](formats.md),
and [operation conveniences](operations.md).

See [compatibility](compatibility.md) for qualified components,
[testing](testing.md) to reproduce checks, and [status](status.md) for
remaining adoption requirements. The [README](../README.md) contains a complete
private-server walkthrough.
