# Current capabilities and adoption gaps

The immutable model, typed queries, native Linux clients and output observation
have real-tmux evidence on 3.3, 3.3a, 3.4 and 3.8. The complete workspace/CLI/MCP
suite and its final adoption review remain unfinished. No package or
hosted-documentation release has been published.

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
| Workspaces | Finish the Eio adapter, installed CLI, versioned receipts and recovery checks |
| MCP | Ship the stdio service, discovery/catalog schemas, bounded targets and operation lookup; run conformance and host tests |
| Documentation site | Finish public `.cmti` export, shared-site rendering and deployed-link verification |
| Benchmarks | A [serial capture harness](benchmarking.md) is available; add concurrency, graph scaling, allocation and stream-latency workloads |
| Final qualification | Rerun every required component and exact release cell on the final source revision |
| Package adoption | Obtain an independent caller-task review and resolve material findings |

The workspace model and JSON loader are implemented. The blocking executor has
live tests for partial effects, compensation, append isolation, stale plans and
cancellation journals. Those results do not establish an installed CLI or a
complete cross-backend workspace product.

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
