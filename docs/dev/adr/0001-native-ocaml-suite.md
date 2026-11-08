# ADR 0001: Native OCaml snapshots and explicit tmux control

## Abstract

libtmux for OCaml separates captured observations from live control. The core
provides immutable graph values, typed expressions and command descriptions.
Optional packages provide blocking Linux and Eio clients, JSON interchange,
workspace execution and a CLI. Ordinary OCaml collections and functions remain
the primary way to process observations.

The primary workload is a local Linux application that needs captured graphs,
retained command outcomes and bounded live observation. The persistent client
serves those automation requirements; it is a larger dependency than a script
that occasionally runs a tmux command needs.

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
[typed filtering API](https://github.com/libtmux/libtmux-java/blob/v0.1.2/docs/guide/filtering.md#L21-L26)
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

Immutable observations and local evaluation are API guarantees. Source
generation equality and queue limits are identity and resource policies.
Passing a workload on one tmux release is qualification evidence. None of
those establishes that another release, workload or deployment is supported.

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
| [libtmux-unix](../../../unix/) | Blocking client, workspace executor and private native transport engine | Core, pure workspace, Unix and Linux C bindings |
| [libtmux-eio](../../../eio/) | Concurrent client and workspace executor | Native engine and Eio |
| [libtmux-json](../../../json/) | Validated query/workspace interchange | Pure packages and Yojson |
| [libtmux-workspace-cli](../../../cli/) | Installed `tmux-workspace` command | Optional clients, JSON and CLI dependencies |

Internal package versions move together. Opam manifests are authored directly;
Dune builds and installs the libraries. Tests and documentation tools do not
become core runtime dependencies. See [package selection](../../packages.md).

Exact external dependency constraints currently serve both qualification and
installation. This narrows the dependency combinations a downstream switch can
accept. A future distribution range needs consumer qualification separately
from the reproducible development environment. The current-compiler-only
policy remains exact; relaxing other dependencies does not authorize older
compiler support.

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

[`Snapshot.create`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L436-L471)
validates references and graph invariants. Equal duplicate global rows collapse
in first-occurrence order; conflicting rows and dangling references fail.
Capture records start and finish times. Several listing commands do not form
an atomic transaction. A failed acquisition cannot become an empty successful
snapshot, and an unloaded relation cannot masquerade as an empty relation.

Each entity retains the entire captured arena. Keeping one pane from each
refresh keeps each corresponding graph alive. A detached scalar summary avoids
that retention; a target also omits the graph but retains its source-generation
restriction. Relationship traversal can allocate wrapper arrays before an
expression stops testing children. Measure retained heap and traversal costs
before introducing partial capture or caches.

Materialization can fail during concurrent graph changes. Its benefit is a
complete local graph without per-object subprocesses or surprise refreshes.
Partial snapshots would need a distinct completeness contract that separates
unloaded, absent and empty relationships.

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

The public interfaces define
[relationship quantifiers and cardinality](../../../lib/libtmux.mli).
Select before mutating; that sequence still does not lock the server. See the
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

The capabilities differ by layer:

| Layer | Available behavior | Boundary |
| --- | --- | --- |
| Observation accessors | Captured scalars and relationships, including optional values such as `Pane.pid` | Reading an option does not make it a registered expression field |
| Native expressions | Registered Boolean, integer and text fields; typed relations and Boolean composition | Arbitrary functions remain ordinary predicates |
| Query JSON | Shared scalar pane registry and Boolean composition | Native-only fields, relationships and Java regex are rejected |
| Source planning | Exact pane active/dead predicates and supported Boolean composition | Unsupported conditions remain local or fail `Require_exact` |
| Current clients | Complete graph acquisition and local evaluation | Capture does not execute source plans |

This is the capability boundary for interoperability. A generated format
catalog describes names and availability; it does not acquire extra fields.

### Keep connection ownership and operational identity explicit

[`Endpoint`, `Generation` and `Source`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/lib/libtmux.mli#L22-L108)
separate socket descriptions, observed daemon identity and a fresh connection
nonce. Imported source metadata does not establish a live binding. Backends
validate the binding before admitting operations. Targets carry their source;
old targets cannot silently retarget a replacement daemon or connection.

Use explicit identity functions instead of structural comparison.
`same_entity` means the same entity within the same bound source generation.
Independent connections do not establish that equality merely by observing
equal daemon PIDs and entity IDs. A valid target establishes authority, not
freshness of its captured name, geometry or membership. Cross-connection
correlation would need a separate contract. Captured client names have
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

### Drive tmux control clients and classify each response route

The native backend launches the tmux executable in control mode; it does not
implement tmux's private socket protocol. The primary invocation uses `-u`,
`-N` and an explicit endpoint, then `-C attach-session -E -f no-output`.
Additional client flags control sizing and release-specific detach behavior.
Each observation lane attaches to a session because that membership determines
which panes' output tmux forwards. Attachments affect client counts and hooks,
appear in `list-clients` and can be detached by other clients.

The engine serializes ordinary jobs. Each control request has a completion
marker in addition to its command reply. Waiting operations use a separate
bound lane. Public environment, option and hook acquisitions use registered
one-shot command processes so arbitrary response bytes cannot impersonate
control guards. Their PID, completion marker, diagnostics and original pidfd
are checked before the result is accepted. They never carry mutation retries.
Rendered capture's hook preflight is a separate path: its eight hook-scope
reads still use the control lane.

Rendered capture currently checks applicable hooks, creates an owned paste
buffer, reads its size, saves it to a private file and removes it. This adds
shared-filesystem access, synchronous daemon file work, system-thread work in
Eio and a buffer visible to other clients. Output-producing or interfering
hooks are outside that route's contract. A raw read-process capture is a
candidate optimization, requiring equivalent byte, binding, hook and cleanup
evidence before adoption.

The framer relies on tmux's guarantee that notifications occur outside command
output blocks. Group attribution also depends on flags 1 for direct control
commands and 0 for hook commands. The
[manual's flags description and notification rule](https://github.com/tmux/tmux/blob/3.8/tmux.1#L9087-L9109)
do not document that distinction; the implementation derives it from
[`CMDQ_STATE_CONTROL`](https://github.com/tmux/tmux/blob/3.8/cmd-queue.c#L585-L605).
Connect already requires direct-command attribution. Release qualification
must exercise both classes; an unknown flag cannot silently become a reply.

Joining listings reduces round trips but does not make a snapshot atomic.
tmux runs
[after-list-windows hooks](https://github.com/tmux/tmux/blob/3.8/cmd-list-windows.c#L44-L56)
between commands; a hook can change the graph before the next listing. Keep
validation, acquisition timestamps and explicit race failures for grouped
acquisition too. Command-list and flags behavior are versioned implementation
dependencies, not timeless protocol guarantees.

Version admission currently accepts tmux 3.3 and later. The required exact
qualification cells are 3.3, 3.3a, 3.4 and 3.8, with 3.2a rejection tested
separately. Admission does not imply catalog availability or qualification of
every intermediate or future release. Ordinary component passes do not qualify
intensive observation: the recorded 3.4 mixed-workload failure and unexplained
earlier 3.3 observer failure remain open in
[compatibility](../../compatibility.md).

### Share protocol semantics while preserving each runtime's cancellation

The blocking and Eio adapters use the same private
[`Engine` state machine](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/unix/engine.ml#L1-L40)
and connection/streaming machinery. The
[`Eio adapter`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/eio/libtmux_eio.ml#L45-L122)
supplies runtime-specific process, readiness and cancellation operations. This
is an internal boundary, not a public functor that every caller must configure.

The application owns the Eio scheduler, switch, process manager and clock.
[`Eio.Switch.run`](https://github.com/ocaml-multicore/eio/blob/v1.6/lib_eio/core/switch.ml#L128-L156)
provides the enclosing resource lifetime. Client-owned fibers drain commands
and read streams. Pipe readiness is asynchronous; local scratch-file work runs
on a system thread and must finish its cleanup. The library does not start an
independent scheduler.

The adapter extracts raw descriptors through Eio's
[`Fd.use_exn`](https://github.com/ocaml-multicore/eio/blob/v1.6/lib_eio/unix/fd.mli#L29-L33)
and retains them in the private engine. The enclosing flow/switch ownership
and worker-close ordering must keep those descriptors valid beyond the
callback. Callback scope alone does not prove that lifetime. Deadline
arithmetic also uses the native monotonic clock, so supplying an Eio clock
does not establish deterministic virtual-time testing.

The blocking client starts no worker or scheduler. Its awaiting caller pumps
admitted work. Scoped cancellation tokens can wake it from another domain or
systhread. Cancellation drains written work before raising, subject to the
documented exchange bound and completion of local scratch I/O. Live handles
belong to their creating OCaml domain; immutable observations can be shared.

The reviewed baseline does not bound owned-child shutdown: both adapters send
TERM and then await exit without a grace deadline or escalation. Protected
Eio cleanup can therefore wait indefinitely. Its blocking readiness also uses
`Unix.select`, whose
[descriptor check](https://github.com/ocaml/ocaml/blob/5.5.2/otherlibs/unix/select_unix.c#L35-L44)
rejects descriptors outside `FD_SETSIZE`. Blocking readiness now uses a shared
private `poll` binding for protocol work and terminal attachment.

Owned-child shutdown now uses one private policy across both adapters and
terminal helpers: send TERM, allow 200 ms of cooperative grace, then force
termination if needed and reap. Eio uses its process handle and asynchronous
monotonic timer; the blocking adapter waits on the owned child's pidfd. Failed
pidfd acquisition skips the grace and proceeds to forced termination. The
daemon remains outside this policy. Grace is per child, not a whole-client
deadline. Exchange deadlines, owned-child grace and filesystem completion are
separate bounds; no library deadline bounds uninterruptible kernel work.

Process and descriptor cleanup now records secondary failures in a caller-owned
`Cleanup` report. Creating the report before connection, bootstrap or terminal
attachment preserves evidence even when no client is returned. Successful
clients expose their supplied report or a fresh default. Reports retain a
typed library cause when available, the original exception and its backtrace.
Their 64-entry bound limits count, not the heap retained by exception payloads.
Reports belong to their creating domain and are not immutable graph snapshots.

Cleanup attempts independent finalizers before propagating its first failure;
an existing primary exception retains its identity and backtrace instead.
Native cancellation is not combined with or converted into a cleanup error.
After a failed KILL, only an already established exit permits reaping: an
unconfirmed exit produces an `Unreaped_child` diagnostic instead of an
unbounded await. Concurrent Eio client closes now share one completion result,
including its original failure. A closing flag elects the teardown owner and
stops the pump; it does not establish completion. Eio descriptor ownership,
admission during close and overlapping resource closure remain open lifecycle
work.

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
[control-mode framing](https://github.com/tmux/tmux/blob/3.8/tmux.1#L9068-L9109)
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

Admission limits are resource policies. Command slots, queued bytes, frame and
field sizes, graph rows, subscriptions, lane count and capture payloads each
have bounds, alongside aggregate accounting. The shared lane pool also serves
reads and waits, so observers can exhaust their capacity. Raising a per-object
limit cannot bypass aggregate reservation. These limits bound library-owned
payloads, not caller-retained snapshots, process RSS or tmux's own allocations.

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

### Keep workspace planning pure and retain execution progress

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
The versioned native schema keeps path expansion, argv/shell distinctions and
validation explicit. A tmuxp loader would be a separately qualified translation
layer, not a change in the meaning of existing documents.

Plans retain collision policy and generation-bound targets. Execution rechecks
preconditions and applies once per execution handle. Explicit bootstrap handles
a missing endpoint; it does not turn missing acquisition data into an empty
graph. Append mode
rejects conflicting windows and preserves the documented session constraints.

[`Execution.await`](https://github.com/libtmux/libtmux-ocaml/blob/53a51bed2caa198be0fc3d81cb464e29d9f29403/workspace/libtmux_workspace.mli#L248-L258)
retains ordered step outcomes, creations and uncertainty. Cancellation records
progress and propagates. Optional compensation targets only panes whose
creation is proven by completed commands, in reverse order. Borrowed panes and
containers with foreign content remain. Compensation is partial recovery,
not transaction rollback, and its failures have separate outcomes.

The journal is retained in process memory while its execution object remains
available, including across waiter cancellation and client closure. It is not
a durable write-ahead log. A new handle or CLI invocation is a new execution;
operation IDs correlate outcomes and provide no deduplication. Compensation
cannot undo files, network requests or other effects of programs started in
panes. Forced process termination cannot guarantee delivery of a CLI receipt.

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

Cross-language compatibility needs a reproducible pinned Java qualification
path, including both evaluator and codec directions. The existing scratch
checkout/cache-dependent runner is recorded evidence, not a continuously
maintained CI guarantee. Keep it separate from core dependencies and fast
tests. The current query property test varies values against a fixed compound
expression; it does not generate arbitrary expression trees.

This requires maintaining fixtures and documentation tooling alongside the
library. It makes examples and contracts reviewable without forcing a browser,
JSON library or concurrency runtime into the pure core.

## Alternatives and consequences

The strongest smaller alternative keeps the same immutable graph, typed
expressions, cardinality and standard collections, backed by one-shot
acquisition and explicit commands. It reduces persistent resource management
and qualification work for occasional scripts. Continuous observation and
retained written-operation outcomes would still need additional machinery.
The selected transport pays that cost because stateful automation and live
observation are required workloads. Pure query ergonomics do not justify the
transport complexity by themselves.

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

Also revisit transport attribution if command-list grouping or flags change;
deadline/closure policy if bounded resynchronization is introduced; and the
public integration boundary when engine-ops chaining, tmuxp translation or
format subscriptions have a concrete consumer. The current `Command.view`
supports typed inspection, not arbitrary engine injection. Add a focused
decision record when one of these contracts changes independently.

Architecture review should evaluate those contracts against the linked source.
Release readiness remains a separate decision based on the exact candidate's
full checks and installed-consumer evidence.
