# Compatibility

The compiler target is **OCaml 5.5.2**, exactly pinned. Older compilers are
outside this implementation's scope. The development tools are Dune 3.24.2
and opam 2.6.1.

The implementation supports Linux and **tmux 3.3a–3.8**, including every
intermediate release. CI tests only the two endpoints, 3.3a and 3.8. Option and
format catalogs cover the entire range. Current evidence covers specific
components; final suite qualification has a separate acceptance gate. The table
records the exercised fixtures, not every possible cleanup path.

| Component | 3.3a | 3.8 |
| --- | --- | --- |
| Owned fixture teardown | PASS | PASS |
| Exact Boolean pane filters | PASS | PASS |
| Argument and metadata byte codecs | PASS | PASS |
| Split control framing and command groups | PASS | PASS |
| Bound graph capture and ordinary client teardown | PASS | PASS |
| Replacement-daemon rejection | PASS | PASS |
| Private-file capture and failed-save callbacks | PASS | PASS |
| Eio waiter cancellation and retained outcomes | PASS | PASS |
| Blocking cancellation and bounded drain | PASS | PASS |
| Command and lane admission limits | PASS | PASS |
| Environment bytes, scopes and read-process lifecycle | PASS | PASS |
| Scoped options and built-in hook execution | PASS | PASS |
| Current client names and detach-request semantics | PASS | PASS |
| Interactive attachment, cancellation and child exit | PASS | PASS |
| Versioned format availability and generated APIs | PASS | PASS |
| Native operation inventory | PASS | PASS |
| Data/Gap/End, stream limits and recovery | PASS | PASS |
| Installed stream-gap walkthrough | FAIL | FAIL |
| Rendered waits and future-byte matching | PASS | PASS |
| Blocking/Eio workspace preconditions and compensation | PASS | PASS |
| Public workspace bootstrap on fresh/existing daemons | PASS | PASS |
| Installed workspace CLI, receipts, interruption and output faults | PASS | PASS |
| Literal workspace guide and owned teardown | PASS | PASS |
| Native workspace interruption caller and guide | PARTIAL | PASS |
| Final suite qualification | UNVERIFIED | UNVERIFIED |

The [stream-gap walkthrough](streaming.md#recover-after-a-gap) reported an
unknown operation outcome after its recovery output on tmux 3.3a in
[hosted run 42516374421](https://github.com/libtmux/libtmux-ocaml/actions/runs/42516374421).
A bounded diagnostic reproduced the failure with the owned daemon no longer
alive. Its exit cause remains unresolved. Earlier component passes do not
establish that the affected workload is safe.

On tmux 3.8, the same walkthrough exited with status 2 in
[hosted run 42533145236](https://github.com/libtmux/libtmux-ocaml/actions/runs/42533145236).
Its harness captured but did not include the program's output in the raised
exception, so the failure's cause is unestablished. That run passed the ordinary
native component suite before failing the installed example. Keep this result
separate from the earlier 3.3a daemon-exit evidence; it does not prove the same
cause. The example runner now includes captured output and the original cause
when a program fails or times out. Later passing runs do not close either
finding.

The [workspace interruption caller](workspace-recovery.md) passes installed
compensation and foreign-link preservation checks on both endpoints. Its literal
guide also passes. An earlier tmux 3.3a consumer-harness readiness command exited
with status 1 before releasing the creation hook. That failure did not retain
the command's captured output, so its cause remains unestablished. The current
runner retains command, consumer and cleanup diagnostics. Later passing cases
do not close the earlier readiness finding; the 3.3a cell remains partial.
Installed checks verify compensated pane exit, seed topology and client counts.
The foreign-link control renames the created session and requires the ID-based
postcondition to report failure while preserving foreign content.

The current matrix uses only OCaml 5.5.2 and tmux 3.3a/3.8. Pure assertions
check version rejection and catalog availability across the supported range.
Intermediate releases remain supported without separate runtime CI cells;
earlier runtime results remain evidence for their tested workloads. Development
tmux 3.8a does not replace the published 3.8 cell. PID-acquisition races and
malformed replies after writing pass deterministic fault checks with real Linux
child processes. Cancellation at each capture transfer step and unresolved-buffer
receipts also pass on the
recorded release fixtures. Ready I/O still checks its deadline; busy pipes
cannot bypass the timeout. These results remain evidence for those tested cases.
MCP integration is outside this port's scope.

Owned-child cleanup sends TERM, allows a 200 ms cooperative grace, then sends
KILL if necessary and reaps the child. The policy covers control, read-process
and terminal helpers; it never sends these signals to the daemon. Eio waits
allow other fibers to progress. The grace applies per helper, not to the whole
client, and cannot bound uninterruptible kernel work or scratch-file completion.
Caller-owned `Cleanup` reports retain secondary process and descriptor failures
without replacing native cancellation or the primary exception. Independent
releases are still attempted. A failed KILL only permits a nonblocking exit
check; an unconfirmed exit is reported as `Unreaped_child`. Concurrent Eio
client closes await one retained teardown result. The Eio runtime owns its pipe
ends explicitly and joins their readiness waiters before closing them. Process
I/O rechecks closure after yielding, preventing access to reused descriptors.
A private Eio process owner keeps its reaper alive through cancellation and
switch release; callers join its completed teardown. Shutdown regressions cover
both Eio's Linux and POSIX backends on Linux. This does not add platform support.
New commands and subscriptions are rejected as soon as client close starts.
Connection and subscription teardown also retain one completion: overlapping
Eio callers join it, and later calls preserve its failure.

The shutdown regression checks stopped helpers and helpers that survive TERM
and input closure, while keeping the parent and its Eio switch alive to verify
reaping. These are injected helper failures, not naturally reproduced hangs in
a supported tmux daemon. Blocking readiness uses `poll`; ready reads, ready
writes and deadlines work above descriptor 1100. Terminal attachment and
cancellation also have high-descriptor evidence on the previously tested
3.3/3.3a/3.4/3.8 fixtures. See the
[architecture's cleanup boundary](dev/adr/0001-native-ocaml-suite.md#share-protocol-semantics-while-preserving-each-runtimes-cancellation).

The near-limit [mixed workload](benchmarking.md#mixed-commands-stream-pressure-and-membership-changes)
reproduces a tmux 3.4 daemon crash in the control-client detach notification
path. The exact 3.8 source includes the upstream null-state guard. An earlier
3.3 observer-command failure remains unattributed. Passing ordinary client
checks does not close either mixed-workload failure.

tmux 3.2 through 3.8 also abort the daemon with `fatal: not enough data` when a
control client leaves, or is set to ignore output, while a queued output block
is unwritten and its pane prints again. `control_write_output` in `control.c`
advances the client's offsets past the pending bytes, and `control_append_data`
then finds fewer bytes than the block records. It is a race, so the failure
rate depends on load: 20 of 20 and 19 of 20 runs of a 100-round
close-while-echoing regression killed the daemon on 3.8 and 3.3a, and 8 of
1200 runs of the stream-recovery walkthrough did under CPU load on 3.8. A
subscription lane now pauses each pane it observed before closing; pausing
discards the queued blocks. This guards the port only. Other control clients
that disconnect mid-output can still trigger the abort.

The I/O packages require Linux pidfds, the same PID namespace as the daemon,
and shared local scratch storage. A socket pathname does not prove those
conditions. Each connection has its own generation; a replacement daemon never
inherits old targets. Closing a client releases its own processes and leaves
the daemon running.

The blocking client accepts a scoped `Cancellation` token that another domain
or systhread can cancel. It drains admitted work before raising
`Cancellation.Cancelled`. The drain has at most one exchange timeout from
detection; subsequent owned-child cleanup has its separate cooperative grace.
The operation handle retains success, failure or uncertainty. Eio cancellation
releases the waiter immediately while a client-owned fiber drains the work.
Local scratch I/O must finish in either case; Eio performs it on a system
thread. Filesystem failures have a distinct error from transport disconnects.

Pane PIDs and client terminal heights can be absent. The model exposes these as
options; a control client without a started terminal has no reported height.
tmux itself sanitizes names on older releases and rejects some names on newer
releases. Captures preserve the observed value rather than reconstructing the
argument originally submitted by another client.

Control commands use ASCII escapes for non-ASCII bytes because tmux 3.3's
command-string lexer can confuse a signed `0xff` byte with EOF. Metadata uses
tmux's `q` format modifier and preserves physical newlines. A fixed read probe
detects the additional visual escaping used by tmux 3.4 before decoding it.
Control clients must request UTF-8 mode so locale-dependent sanitization cannot
alter captured bytes.

An end guard acknowledges a command. Completion requires the operation's
postcondition or a following marker on its lane. A control client may exit
with status 1 after an earlier command failed, even when later commands and
shutdown succeeded. Tests retain that distinction.

The optional JSON codec supports the scalar pane registry and Boolean nodes
from Java's [`libtmux.filter/1`](query-interchange.md) at revision
`e8a39689d8d60968ac978a1dd2a89c6112333896`. Both implementations agree on 66
captured-value cases and read each other's encoded queries. Numeric operands
use signed 32-bit bounds. Regex, relationship documents, numeric membership
and native extension fields remain unsupported in this wire schema.
The [conformance procedure](../test/conformance/README.md) rebuilds the peers
from identified inputs and retains both codec directions and artifact digests.
It is a separate qualification command, not part of ordinary hosted OCaml CI.

Reproduce native checks with the commands in
[CONTRIBUTING.md](../.github/CONTRIBUTING.md). The fixture builders use official
release archives and retain archive and binary digests under `scratch/tmux/`.

Environment reads use a bounded read-only process on the same daemon. The
client checks its reported PID and the original pidfd after collecting the
complete response. Values may contain control-marker text without entering
the control parser. Replacement, malformed data, truncated output and capacity
failures never become a successful empty table. This route does not execute
mutations or reconnect the primary lane.

Scoped options preserve scalar types, sparse array indexes and local versus
inherited entries. Bulk inherited enumeration follows tmux and includes only
built-ins; `read_option` resolves a named inherited user option. Descriptors are
recorded for every supported release in the [option catalog](options.md). tmux
fills the lowest unused indexes when appending array elements.

Hook commands keep names and arguments separate. Built-in hook arrays report
synchronous failures; earlier effects remain after a later command fails. Named
`@` hooks can be configured, read and removed, but `run_hook` rejects them because
tmux may hide parse failures in the server log. Hooks that print arbitrary output
remain outside the supported control transport contract.

Captured client names belong to a connection generation but may be reused within
it. Operations address the client currently bearing that name. A detach request
confirms command processing, not peer exit; callers need separate exit evidence.
Switching an existing client does not create a new terminal.

`Terminal.attach_current` opens an interactive terminal against an explicit
endpoint and session ID. This separate utility is unbound: an ID can refer to a
different daemon if the endpoint changes. It accepts no captured target and
never retries or starts a daemon. Both backends wait for the terminal client to
exit and reap it on cancellation. Supplied terminal streams remain caller-owned.

The generated [format catalog](formats.md) records exact-release availability
and callback contexts. Local `Formats.lookup` distinguishes captured values,
missing values, unacquired fields and fields unsupported by that release.
It does not perform arbitrary format acquisition. Generated
[operation conveniences](operations.md) share the same command constructors
between Unix and Eio; the installed-consumer test exercises both adapters.
