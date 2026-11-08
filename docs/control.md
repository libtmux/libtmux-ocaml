# Submit actions and retain their outcomes

Observations are local values. Client calls perform explicit I/O, and mutations
use targets bound to the source that produced them. Closing a client releases
its own transports. tmux then applies its configured lifetime: for example,
[the standalone programs](showcases.md) enable `exit-unattached` on their
private daemons so they exit after their final client detaches.

The [layout program](../examples/native_build.ml) creates a session, splits its
first pane and adds a logs window. It passes argv through `Spawn.Exec`, a working
directory and an environment value. `Spawn.Shell` explicitly requests shell
code. `send_text` is literal input; `send_keys [Key.Enter]` is a separate action.

A creation response returns the reported session, window and pane IDs without
an extra graph capture. Only the resource requested by that command is newly
created. A split's returned session and window are pre-existing containers.

## Choose a backend

Use `Libtmux_unix.Client` in a blocking script. Use `Libtmux_eio.Client` inside
an application-owned Eio switch, supplying the process manager and monotonic
clock. Clients are affine to their connecting domain. Immutable captured values
can be read from other domains; live client handles cannot move between them.

The Eio backend has client-owned workers for command draining and stream
reading. A cancelled waiter does not abandon a written request. Local scratch
filesystem work runs on a system thread. The blocking backend supports scoped
cancellation tokens signalled from another domain or systhread.

| Recovery concern | Eio | Blocking Unix |
| --- | --- | --- |
| Cancel one caller | Eio cancellation scope around `Client.await` | `Cancellation.with_` token passed to `Client.await` |
| Return after cancellation | The waiter raises while a client-owned fiber drains admitted work | The call drains before raising; one exchange timeout after detection bounds transport work |
| Inspect an outcome | `Operation.inspect`, on the connecting domain | `Operation.inspect`, on the connecting domain |
| Release resources | Close the client inside its application-owned switch | Close the client after the call returns |

The blocking bound covers transport draining. Local scratch I/O must still
finish before the call returns.

Concurrent Eio `Client.close` calls wait for the same teardown result. A later
close retains an earlier teardown failure; the closed state alone does not
prove resources were released. Inspect the client's `Cleanup` report for
secondary failures.

The [complete recovery example](recovery.md) cancels an active waiter, awaits
the same retained operation and checks server state before its next mutation.

## Distinguish acknowledgement from completion

`submit` validates and reserves capacity without writing. Retain the operation
handle before awaiting it. `Operation.inspect` reads its state without I/O:
queued, not started, written, acknowledged, finished, or outcome unknown.

A reply can acknowledge a command while hooks or its completion marker remain
outstanding. Sending keys confirms tmux accepted input; it does not prove a
terminal program consumed it or completed work. A detach request does not prove
the peer exited. Use the relevant postcondition, rendered wait or external exit
signal for the task.

Expected failures use `result` and `Error.t`. Backend cancellation propagates
as cancellation. An uncertain result retains reported creation IDs and unresolved
owned buffers; it never becomes an instruction to retry the mutation.

`Client.cleanup` retains process and descriptor cleanup diagnostics after
closure. Supply a `Cleanup.create ()` report through `~cleanup` before connecting
when diagnostics must survive failed setup or cancellation. The same option is
available on terminal attachment and workspace bootstrap. `Cleanup.inspect`
returns the cleanup phase, typed library error when available, original
exception and backtrace without I/O. The report retains at most 64 entries and
counts further issues; exception payloads can still retain substantial memory.
Reports and their diagnostics belong to the creating domain.

Cleanup attempts independent releases even when one fails. A primary exception
keeps its identity and backtrace; secondary failures go to the report. If there
is no primary failure, the first unrecovered cleanup failure is returned or
raised normally. A recovered fallback can still leave a diagnostic alongside
`Ok`: failure to open a child pidfd skips TERM grace, forces termination and
reaps, while retaining the `Open_pidfd` issue.
Failed forced termination produces an `Unreaped_child` issue when exit cannot
be established without blocking. That issue does not prove resource release.
The [recovery example](recovery.md) keeps its report outside connection lifetime.

## Recover deliberately

A replacement daemon retires the connection generation. Reconnect explicitly,
capture again and establish cardinality before choosing a fresh target.
Old captured values remain readable, but their targets cannot silently move to
the new server.

Partial effects can remain after a later hook or command failure. Inspect the
retained receipt and current server state. Compensate only resources whose
creation is proven. A snapshot is an observation over an interval, and a
selection followed by mutation is not an atomic transaction.

Use the [recovery walkthrough](recovery.md) to follow this sequence through a
complete installed program, including cleanup of its own pane.

See [streaming](streaming.md) for Data/Gap/End and bounded queues, and
[compatibility](compatibility.md) for hook, PID-namespace and scratch-file
constraints. [Guide](README.md) · [API](api.md)
