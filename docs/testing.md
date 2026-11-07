# Testing and CI

Use Alcotest for typed values and lifecycle invariants, `ppx_expect` for readable
output contracts, and QCheck for generated semantic cases. All three run through
Dune. The pure runtime library uses the standard library; the PPX is a test-only
dependency.

The [cardinality tests](../test/core_test.ml) compare typed results using an
`Alcotest.testable` with `Cardinality.pp_error`. A failure displays the expected
and actual values, including the error variant's meaning. Comparing a Boolean
expression would only report `true` versus `false`. Keep testable printers small
and show the values needed to understand the failure.

The [expect tests](../test/diagnostics_expect.ml) place expected diagnostic text
beside the code that prints it. A mismatch produces a diff and a `.corrected`
file. Inspect the changed meaning before promoting an expectation. Stable query
explanations, error messages and CLI output fit this style. Avoid snapshotting
timestamps, random IDs or whole server captures to test a small invariant.

[QCheck cases](../test/query_test.ml) compare typed-expression evaluation against
native predicates with generated inputs. A fixed seed makes the current suite
reproducible; shrinking helps explain counterexamples. Properties supplement the
small authored edge cases and live tmux checks.

Run the unit, expect, property and compile-failure suite:

```console
$ opam exec -- dune runtest --force
```

Cold PPX driver compilation belongs to setup or an outer build. Time the warm
test command separately and retain the existing inner/mid budgets. Native and
installed-consumer checks belong to the outer loop because they launch processes
and own real tmux servers.

Run the implemented native contract suite against one explicit release binary:

```console
$ opam exec -- python3 test/native_suite.py /path/to/tmux
```

The [CI workflow](../.github/workflows/ocaml.yml) uses exactly OCaml 5.5.2,
Alcotest 1.9.1, `ppx_expect` v0.17.3 and QCheck 0.91. It checks authored manifests,
builds/odoc, generated files, formatting, unit/expect/property cases, four native
release cells and separate 3.2a rejection. Each native cell installs the packages
into a temporary prefix and runs a consumer outside the checkout. Consumer
features still in development need their own later acceptance gates.

`ocaml/setup-ocaml` caches opam and the switch. The tmux composite action caches
only an installed prefix, keyed by source, runner image/version, architecture,
compiler, package versions and build/probe recipes. Dependencies are installed
before validating either hits or misses. A restored binary must match its hash,
report the exact release and pass an owned-daemon probe with verified teardown.
Rejected caches rebuild; no broad restore key reuses a binary from another
environment. Save a validated installation before running library tests.

The cache design adapts the [Go port's pinned implementation](https://github.com/libtmux/libtmux-go/blob/d8ea6f77ede9f75e96af78719c8c1707fc47bdfb/.github/scripts/tmux_build.py).
The APIs and testing styles follow the primary documentation for
[setup-ocaml](https://github.com/ocaml/setup-ocaml/tree/ff66428f72b64472e749b22e0ad4dded4b2ddca6),
[Alcotest](https://github.com/mirage/alcotest/tree/1.9.1),
[ppx_expect](https://github.com/janestreet/ppx_expect/tree/v0.17.3), and
[Dune tests](https://dune.readthedocs.io/en/stable/tests.html).

## Executed documentation

README and guide snippets name regions in the compiled programs under
`examples/`; JSON includes use the complete shipped configuration. The source
is authoritative; this check rejects drift:

```console
$ python3 tools/docs_snippets.py
```

The installed-consumer test installs libraries into a separate prefix, builds
every shipped example in an independent Dune project and runs it against owned
tmux servers. It checks linked-window contexts, typed/native query results,
created layout geometry, options, pane titles, working directories, literal
input, future-byte matches, rendered-screen waits and zero remaining clients.
Owned fixture teardown verifies pane and daemon exit.

The [standalone capability programs](showcases.md) include their own private
server setup. CI copies their whole source files into an independent Dune
project and executes the recorded `opam exec -- dune exec` commands against
installed packages. Exact outcome lines and owned process/directory teardown
are checked. The [inventory](../examples/showcase.json) records each source and
command with its native workflow/job and tmux floor.

Each native CI cell also runs the [workspace guide](workspaces.md) through real
`opam exec` and an installed `tmux-workspace`. It executes the displayed setup,
validation, plan, apply and cleanup commands, then checks receipt fields, pane
directories, layout output, client closure and owned process exit. CLI fault
tests pin their output pipe capacity so a larger host pipe cannot turn a
stalled-consumer test into successful buffered delivery.

These are correctness checks and whole-command timings, not throughput
benchmarks. Do not derive performance comparisons from their durations.

[Guide](README.md) · [API](api.md) · [Compatibility](compatibility.md)
