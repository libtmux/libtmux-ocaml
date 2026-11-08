# ADR 0001: Native OCaml snapshots and explicit tmux control

## Abstract

libtmux for OCaml separates captured observations from live control. The core
provides immutable graph values, typed expressions and command descriptions.
Optional packages provide blocking Linux and Eio clients, JSON interchange,
workspace execution and a CLI. Ordinary OCaml collections and functions remain
the primary way to process observations.

## Status

Proposed record of the implemented architecture, dated 2026-11-08. The design
has been adopted for implementation; this record awaits architectural review.
Accepting it does not establish complete-suite adoption, a package release or
hosted-documentation qualification. [Current status](../../status.md) and
[compatibility](../../compatibility.md) own those changing results.

The reviewed implementation is
[the immutable source baseline](https://github.com/libtmux/libtmux-ocaml/tree/53a51bed2caa198be0fc3d81cb464e29d9f29403).
The port has no release tag at this baseline. Its implementation links below
therefore use that commit; upstream links use existing release tags and line
anchors at the named symbols. Repository-relative links lead to maintained
guides and examples.

## Context and problem

A tmux library must describe a graph that changes while commands run. Windows
can have several session links. IDs alone do not identify a daemon, and a
successful input command does not prove that a program in a pane finished work.
Concurrent callers also need to distinguish cancelling their wait from undoing
effects already sent to tmux.

The Python port's
[`QueryList`](https://github.com/tmux-python/libtmux/blob/v0.62.0/src/libtmux/_internal/query_list.py#L327-L355)
and Java port's
[typed filtering API](https://github.com/libtmux/libtmux-java/blob/v0.1.2/docs/guide/filtering.md#L18-L26)
provide behavioral references. They do not require the OCaml port to copy their
objects, collection wrappers or runtime dependencies. OCaml can express the
model through modules, abstract types, GADTs and standard-library collections.

## Scope and terminology

This record covers the pure model, query language, native clients, workspace
suite, interchange and documentation contracts. It records alternatives and
consequences; public `.mli` interfaces own exact signatures and bounds.

A **snapshot** is a complete validated observation over an acquisition interval.
A **source** identifies an endpoint, observed daemon and connection generation.
A **target** describes an entity in that source. An **operation** retains one
admitted command's progress and outcome. A **subscription** observes future
bytes with explicit continuity boundaries. A **workspace receipt** records
steps, partial effects and compensation outcomes.

MCP integration is excluded by project policy. The automation surfaces are
native OCaml APIs and the workspace CLI. Remote transports, an embedded JVM,
transparent reconnects and tmuxp configuration compatibility are outside this
record's implemented scope.

## Decisions

### Use native modules and a standard-library core

The core uses OCaml modules and abstract types. The exact compiler baseline is
[OCaml 5.5.2 in the authored manifest](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/libtmux.opam#L14-L22).
The policy targets the latest stable compiler in 2026. A later compiler update
requires upstream release verification and package qualification; an exact pin
does not promise support for every future compiler. Older compilers receive no
compatibility layer or test matrix.

The package boundaries are:

| Package | Responsibility | Runtime boundary |
| --- | --- | --- |
| [libtmux](../../../lib/) | Immutable graph, descriptors, expressions, commands | Standard library |
| [libtmux-workspace](../../../workspace/) | Configuration, plans and journals | Core and standard library |
| [libtmux-unix](../../../unix/) | Blocking client and private native transport engine | Linux, Unix and small C bindings |
| [libtmux-eio](../../../eio/) | Concurrent client and workspace executor | Native engine and Eio |
| [libtmux-json](../../../json/) | Validated query/workspace interchange | Pure packages and Yojson |
| [libtmux-workspace-cli](../../../cli/) | Installed `tmux-workspace` command | Optional clients, JSON and CLI dependencies |

Internal package versions move together. Opam manifests are authored directly;
Dune builds and installs the libraries. Tests and documentation tools do not
become core runtime dependencies. See [package selection](../../packages.md).

This costs some adapter code and explicit package selection. It lets a program
inspect a snapshot or validate a native workspace without adopting a scheduler,
JSON library, replacement standard library or PPX. Revisit a boundary when a
concrete external caller needs it, rather than exposing private helpers early.

### Materialize immutable observations and retain window-link context

Snapshots return `Iarray.t`. OCaml's
[`Iarray.t` and read operations](https://github.com/ocaml/ocaml/blob/5.5.2/stdlib/iarray.mli#L18-L49)
provide indexed materialized collections. Entity types expose no mutation.
Accessors, relationship traversal and local query evaluation perform no I/O;
captured values remain readable after client closure.

The graph preserves the distinction in tmux's
[`struct winlink`](https://github.com/tmux/tmux/blob/3.8/tmux.h#L1509-L1525):

```text
Session -> Window_link -> Window -> Pane
              index          ^
                             |
                    another Window_link
```

[`Window_link`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L258-L283)
owns session-specific index and current state. A global window owns panes,
geometry and name. `Session.window_links` preserves repeated windows and
contexts; `Session.windows` is a distinct-window convenience view in first-link
order. A link context does not prove a stable incarnation across unlinking or
reindexing. [The graph example](../../../examples/native_graph.ml) exercises
shared windows.

[`Snapshot.create`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L441-L471)
validates references and graph invariants. Equal duplicate global rows collapse
in first-occurrence order; conflicting rows and dangling references fail.
Capture records start and finish times. Several listing commands do not form
an atomic transaction. A failed acquisition cannot become an empty successful
snapshot, and an unloaded relation cannot masquerade as an empty relation.

Materialization consumes memory and can fail during concurrent graph changes.
The benefit is a complete local graph without per-object subprocesses or
surprise refreshes. Partial snapshots would need a distinct completeness
contract before introduction.

### Compose ordinary predicates with typed query data

Use `Iarray`, `Seq` and `List` directly. Arbitrary executable predicates belong
in `Seq.filter`; inspectable queries use abstract `'entity Expr.t`, typed
`Field.t` descriptors and typed relations. OCaml's
[GADT parameter constraints](https://github.com/ocaml/ocaml/blob/5.5.2/manual/src/refman/extensions/gadts.etex#L1-L9)
support entity/operator correctness. The public
[`Expr` interface](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L552-L639)
offers ordinary constructors, compilation to a predicate and typed inspection.
It cannot add arbitrary closures or accessors to portable expressions.

`Query.matching` compiles once when constructed, preserves order and duplicate
entries, and never acquires data. Snapshot-derived sequences replay captured
values. OCaml's
[`Seq.t` contract](https://github.com/ocaml/ocaml/blob/5.5.2/stdlib/seq.mli#L24-L53)
does not guarantee replayability for arbitrary input sequences. A caller's
stateful predicate can still perform effects or return different answers.

Relationship `any` over no children is false; `all` and `none` are true. One
child must satisfy an entire nested expression. Two separate existential
conditions can match different children. `exactly_one` and `one_or_none`
return cardinality errors, count duplicates and stop at a second match.
Proving uniqueness exhausts the remaining finite input. Select before mutating;
that sequence still does not lock the server. See the
[executed query program](../../../examples/native_query.ml).

[`Plan.panes`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L640-L661)
is a pure planning seam. Exact lowering covers pane active/dead flags and
complete supported Boolean combinations. Unsupported expressions, including
relationships, remain local; `Require_exact` rejects them. Current capture
clients acquire the complete graph and do not execute plans. A future executor
must preserve full relation semantics and avoid losing branches under OR or
changing the meaning of negation.

A mandatory query wrapper, query monad or PPX would add a second collection
vocabulary. The chosen design instead keeps portable data more restricted than
ordinary OCaml functions. That restriction makes validation and planning
possible, at the cost of explicitly composing the two layers.

### Keep connection ownership and operational identity explicit

[`Endpoint`, `Generation` and `Source`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L22-L108)
separate socket descriptions, observed daemon identity and a fresh connection
nonce. Imported source metadata does not establish a live binding. Backends
validate the binding before admitting operations. Targets carry their source;
old targets cannot silently retarget a replacement daemon or connection.

Use explicit identity functions instead of structural comparison. Entity
identity and snapshot observation identity differ. Captured client names have
current-name semantics because tmux may reuse them; the model does not promise
stable client incarnation identity.

Live clients are `Libtmux_unix.Client` or `Libtmux_eio.Client`. A separate live
`Server` object would duplicate endpoint and resource ownership. A captured
`Client_observation` is a row describing an observed tmux client, not a live
library connection. [The control guide](../../control.md) documents the effect
boundary.

The native transport requires Linux pidfd support and a daemon in the same PID
namespace and filesystem. An absolute socket pathname alone does not establish
those conditions. Connect attaches to an existing daemon with a session;
workspace bootstrap is a separate explicit operation. Closing a client releases
owned transports and descriptors. tmux's configured `exit-unattached` or
`exit-empty` policy can subsequently end the daemon.

This limits platform coverage and requires explicit recovery. It avoids making
socket reuse or imported IDs sufficient authority to replay an old operation.
A portable or remote backend must establish an equivalent binding contract
before extending the support claim.

### Share protocol semantics while preserving each runtime's cancellation

The blocking and Eio adapters use the same private
[`Engine` state machine](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/unix/engine.ml#L1-L40)
and connection/streaming machinery. The
[`Eio adapter`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/eio/libtmux_eio.ml#L1-L7)
supplies runtime-specific process, readiness and cancellation operations. This
is an internal boundary, not a public functor that every caller must configure.

The application owns the Eio scheduler, switch, process manager and clock.
[`Eio.Switch.run`](https://github.com/ocaml-multicore/eio/blob/v1.6/lib_eio/core/switch.ml#L128-L156)
provides the enclosing resource lifetime. Client-owned fibers drain commands
and read streams. Pipe readiness is asynchronous; local scratch-file work runs
on a system thread and must finish its cleanup. The library does not start an
independent scheduler.

The blocking client starts no worker or scheduler. Its awaiting caller pumps
admitted work. Scoped cancellation tokens can wake it from another domain or
systhread. Cancellation drains written work before raising, subject to the
documented exchange bound and completion of local scratch I/O. Live handles
belong to their creating OCaml domain; immutable observations can be shared.

Expected failures use `result` and typed variants. Eio cancellation and blocking
cancellation keep their native exception behavior. Catch-all exception
conversion would obscure cancellation and programming defects. Sharing the
engine reduces semantic divergence but couples the two packages' private
implementation; internal versions must stay aligned.

### Retain outcomes and separate acknowledgement from completion

`submit` validates and reserves bounded capacity without I/O. Keep the returned
handle before awaiting. The
[`Operation.state` variants](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/eio/libtmux_eio.mli#L45-L80)
distinguish queued, not started, written, acknowledged, finished and unknown
outcomes. Cancelling unsent work can prevent dispatch; cancelling a waiter
cannot undo a written request. Eio lets the waiter leave while a client-owned
fiber drains it. The handle retains the eventual result on the owning domain,
including after client closure.

tmux's
[control-mode framing](https://github.com/tmux/tmux/blob/3.8/tmux.1#L9068-L9103)
describes command output blocks. The library's acknowledgement state does not
establish final operation completion: hooks or completion markers can remain.
Even a finished `send_keys` operation proves tmux accepted input, not that the
pane program consumed it or exited. A detach response does not prove peer
process exit. Check the postcondition appropriate to the task.

Unknown outcomes retain reported creation IDs and unresolved owned resources.
They never trigger automatic mutation retries. This exposes more recovery
states to callers, but preserves partial effects instead of presenting a failed
wait as proof that nothing happened. The
[recovery example](../../../examples/native_recovery.ml) retains and inspects
the same operation across cancellation.

### Bound future output and make continuity loss observable

[`Output.event`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L1012-L1047)
provides immutable `Data`, `Gap` and `End` values. Cursors are local to a
subscription generation; they do not name a historical server position or a
snapshot instant. Queue admission reserves bounded resources. A slow consumer
can overflow its queue without blocking another subscriber; a gap ends that
subscription's continuity and is followed by `End`.

Subscriptions start after an admission marker. They provide neither history
nor an atomic capture/stream barrier. Membership and layout changes can end
coverage conservatively. Recovery requires a fresh capture and subscription;
the library does not reconnect and reuse a cursor silently.

`wait_for_bytes` searches future bytes and preserves NUL and invalid UTF-8.
`wait_for_text` captures rendered screen text immediately and recaptures after
output; it can establish fresh coverage within the same binding after a gap.
It can miss transient screen contents between captures. Neither API is a
general workload-completion primitive. See [streaming](../../streaming.md) and
[the executed watcher](../../../examples/native_watch.ml).

Bounded delivery sacrifices lossless history for predictable memory use and
isolation between consumers. A durable replay API would need a new storage,
cursor and backpressure contract.

### Validate interchange and keep encoding boundaries separate

Typed field and relation descriptors have canonical registry identities.
External query documents require a model witness and validation before typed
construction. The
[`JSON expression codec`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/json/libtmux_json.mli#L70-L95)
accepts the shared scalar pane subset and Boolean composition. It rejects
unknown or duplicate properties, wrong operands, out-of-range integers and
unsupported semantics. It enforces document, nesting, node and membership
bounds. Native relationships and extension fields are not wire-compatible
merely because local expressions support them.

The shared `libtmux.filter/1` format has
[Java-specific regex semantics](https://github.com/libtmux/libtmux-java/blob/v0.1.2/docs/guide/filtering.md#L140-L154).
The OCaml codec rejects that operator rather than substituting another engine.
Its wire integers fit signed 32-bit values. Native text comparison uses exact
bytes without Unicode normalization or case folding; JSON requires valid UTF-8.
Receipts use a tagged hex representation where required to preserve byte data.
`Marshal` and serialized closures are not interchange formats for this suite.

Process argv, tmux command syntax, tmux format syntax and shell code are
separate encoding boundaries. `Spawn.Exec` describes argv; `Spawn.Shell`
explicitly requests shell code. Literal input and key presses are distinct
operations. The transport owns protocol encoding and decoding. Rendered capture
uses an operation-owned temporary file in the daemon's shared filesystem,
adding filesystem availability and cleanup to the operation's constraints.
See [capture and hook limits](../../compatibility.md).

A broader codec or transport must prove semantic equivalence for each added
operator and encoding. Shared names alone do not establish interoperability.

### Keep workspace planning pure and execution journaled

[`Config`, `Plan` and `Execution`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/workspace/libtmux_workspace.mli#L1-L15)
separate native validation, an ordered preview and effectful execution through
an explicit executor. JSON decoding lives in the optional codec. Relative
directories resolve against the supplied document directory. Only declared
variables expand in directory fields; validation reads neither the process
environment nor the filesystem.

This differs from tmuxp's
[`expandshell`](https://github.com/tmux-python/tmuxp/blob/v1.74.0/src/tmuxp/workspace/loader.py#L13-L28),
which uses user and environment expansion. The OCaml workspace format is
`libtmux.workspace/1`; tmuxp JSON/YAML compatibility is not implied.

Plans retain collision policy and generation-bound targets. Execution rechecks
preconditions and applies once. Explicit bootstrap handles a missing endpoint;
it does not turn missing acquisition data into an empty graph. Append mode
rejects conflicting windows and preserves the documented session constraints.

[`Execution.await`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/workspace/libtmux_workspace.mli#L229-L258)
retains ordered step outcomes, creations and uncertainty. Cancellation records
progress and propagates. Optional compensation targets only panes whose
creation is proven by completed commands, in reverse order. Borrowed panes and
containers with foreign content remain. Compensation is partial recovery,
not transaction rollback, and its failures have separate outcomes.

JSON plans and receipts are advisory documents. Imported IDs or hints do not
establish live bindings and cannot be replayed as execution input. The
[workspace guide](../../workspaces.md) covers validation, preview, apply and
receipt inspection through the installed CLI.

### Make documentation and conformance part of the public boundary

Public `.mli` files own module introductions and contracts for I/O, identity,
ownership, cancellation, ordering, bounds and errors. Native odoc references
link symbols; the shared-site exporter reads public `.cmti` data. Task guides
link to complete programs rather than relying on hidden setup.

[Testing](../../testing.md) uses Alcotest for typed results, `ppx_expect` for
diagnostic diffs and QCheck for semantic properties. Compile-failure cases
check entity/operator mistakes. MDX executes pure reference examples. Snippet
checks prevent prose from drifting from source, and independent installed
consumers execute effectful examples against owned tmux sockets.

Real-tmux qualification uses exact release binaries and checks owned cleanup.
Benchmarks are a separate workload tier; results identify their source and
environment. A passing component or benchmark does not establish a passing
suite, all supported releases or a published consumer installation. Follow
[compatibility](../../compatibility.md), [benchmarks](../../benchmarking.md) and
[adoption gaps](../../status.md) for those results.

This requires maintaining fixtures and documentation tooling alongside the
library. It makes examples and contracts reviewable without forcing a browser,
JSON library or concurrency runtime into the pure core.

## Alternatives and consequences

The strongest smaller alternative is a set of subprocess helpers returning
records and accepting string predicates. That would reduce initial transport
and type machinery. It would leave binding validation, linked-window context,
typed query interchange, cancellation recovery and stream continuity to every
caller. This suite accepts the additional machinery because those behaviors
are part of its public contract.

A mutable ORM or QuerySet façade would match some companion APIs but obscure
the capture boundary and add a second collection vocabulary. A mandatory Eio
core would simplify one transport while imposing a runtime on pure queries.
Independent transport engines would loosen package coupling while duplicating
protocol and outcome semantics. The chosen design keeps the core pure and the
shared engine private.

A Java process bridge could reuse an existing implementation, but would add a
JVM, an RPC lifetime and a graph-decoding protocol. JNI would add in-process
runtime and thread-lifetime obligations. Neither backend is implemented or
required. Companion projects provide semantic references and conformance
fixtures; their successful tests do not establish OCaml support.

The current costs are Linux-specific native control, complete graph
materialization, explicit uncertainty and recovery, restricted wire semantics,
and no transactional workspace rollback. These costs should remain visible
in examples and API documentation.

## Revisit conditions

Revisit this record when a caller requires a portable or remote transport,
partial snapshots, durable output replay, an executed source-filter plan,
additional wire operators, or independent internal package versions. Each
change needs a concrete caller task and evidence preserving the affected
identity, completeness, cancellation and encoding contracts.

Architecture review should evaluate those contracts against the linked source.
Release readiness remains a separate decision based on the exact candidate's
full checks and installed-consumer evidence.
