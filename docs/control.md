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

Captures, reads and subscriptions share the client's payload budget and process
slots. The [capacity guide](streaming.md#plan-shared-capacity) shows their combined
reservations and how to leave headroom for service operations.

Eio `Client.close` rejects new commands and subscriptions as soon as it starts.
Concurrent closes wait for one shared teardown, and a later close keeps an
earlier failure, so a closed client does not prove its resources were released.
Check the client's `Cleanup` report for secondary failures.

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

When Eio's daemon watcher closes a connection, an in-flight operation retains
`Error.Disconnected` as its cause. An idle-reader failure retains its library
error. Explicit client closure uses `Error.Closed`. Inspect the retained receipt
to distinguish these reasons; each can leave an admitted mutation uncertain.

`Client.cleanup` keeps process and descriptor cleanup diagnostics after closure.
Pass a `Cleanup.create ()` report as `~cleanup` before connecting to keep them
through failed setup or cancellation; terminal attachment and workspace
bootstrap take the same option. `Cleanup.inspect` returns the phase, typed
error, original exception and backtrace without I/O.

- A report holds at most 64 entries, counts the rest, and belongs to its
  creating domain.
- Cleanup attempts every independent release even when one fails.
- A primary exception keeps its identity and backtrace; secondary failures go
  to the report. With no primary failure, the first unrecovered cleanup failure
  is returned or raised.
- A recovered fallback can still leave a diagnostic: failing to open a child
  pidfd skips the TERM grace, forces termination and keeps an `Open_pidfd`
  issue.
- If forced termination cannot confirm exit without blocking, the report holds
  `Unreaped_child`; that does not prove the resource was released.

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
