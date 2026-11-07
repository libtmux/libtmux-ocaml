# Current capabilities and adoption gaps

The immutable model, typed queries, native Linux clients and output observation
have real-tmux evidence on 3.3, 3.3a, 3.4 and 3.8. The installed workspace CLI
also passes those cells. The MCP service and final suite review remain
unfinished. No package or hosted-documentation release has been published.

## What an application can use

Capture a complete graph, retain it after closing the client, traverse shared
windows through session-specific links, filter with native predicates or typed
expressions, and establish cardinality before an explicit mutation. Native
operations cover sessions, windows, panes, captured clients, layouts,
environment, options and hooks. Both blocking and Eio transports retain
operation outcomes and expose bounded subscriptions.

The [compatibility table](compatibility.md) identifies qualified components.
The [examples](README.md) are installed, compiled and executed against owned
servers; they cover graph links, query results, created resources, literal
input, streaming, rendered waits and client teardown.

## What is still missing

| Area | Required evidence before complete-suite adoption |
| --- | --- |
| MCP | Ship the stdio service, discovery/catalog schemas, bounded targets and operation lookup; run conformance and host tests |
| Documentation site | Finish public `.cmti` export, shared-site rendering and deployed-link verification |
| Benchmarks | [Serial capture baselines](benchmarking.md) exist; add concurrency, graph scaling, allocation and stream-latency workloads |
| Final qualification | Rerun every required component and exact release cell on the final source revision |
| Package adoption | Obtain an independent caller-task review and resolve material findings |

The workspace model, JSON loader, blocking/Eio executors and installed CLI are
implemented. The [workspace guide](workspaces.md) executes the installed command
through validation, planning, apply, receipt inspection and owned cleanup.
Live tests cover partial effects, compensation, append isolation, stale plans,
cancellation journals and bootstrap on fresh and existing daemons. Cleanup
targets only proven newly created panes; foreign panes moved into a new window
remain. Versioned advisory plans and execution receipts preserve errors,
creation IDs and cleanup outcomes; output documents cannot be replayed as
operational input. CLI checks also cover malformed input, collisions, missing
endpoints, interrupted apply, changed documents and stalled or broken stdout.

## Engineering assessment

For a Linux application needing immutable tmux observations and explicit native
control, the model and clients are candidates for adoption with the documented
constraints. A complete automation suite still needs the missing products and
qualification above. Maintainer count and alpha status do not decide that
assessment; observable behavior and recovery do.

An adopting engineer should expect explicit endpoint selection, client lifetime,
command uncertainty and stream gaps. The package should keep these visible.
Implicit reconnects, callback-driven property acquisition, a mandatory query
wrapper or a required runtime for pure filtering would make the API harder to
reason about.

A 9.5/10 whole-package rating is not established. MCP discoverability,
broader benchmarking and complete-suite installation have open gates. Documentation
quality cannot substitute for those results. [Testing](testing.md) describes
current evidence and how examples are kept in sync with source.
