# Submit actions and retain their outcomes

Observations are local values. Client calls perform explicit I/O, and mutations
use targets bound to the source that produced them. Closing a client releases
its own transports; it leaves the daemon and existing sessions alive.

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

## Recover deliberately

A replacement daemon retires the connection generation. Reconnect explicitly,
capture again and establish cardinality before choosing a fresh target.
Old captured values remain readable, but their targets cannot silently move to
the new server.

Partial effects can remain after a later hook or command failure. Inspect the
retained receipt and current server state. Compensate only resources whose
creation is proven. A snapshot is an observation over an interval, and a
selection followed by mutation is not an atomic transaction.

See [streaming](streaming.md) for Data/Gap/End and bounded queues, and
[compatibility](compatibility.md) for hook, PID-namespace and scratch-file
constraints. [Guide](README.md) · [API](api.md)
