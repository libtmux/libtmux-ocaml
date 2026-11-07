# Observe output and wait for rendered text

Use [native_watch.ml](../examples/native_watch.ml) for a complete concurrent
literal-send, future-byte match and rendered-screen check. Its application owns
the Eio scheduler and switch. Use [native_wait.ml](../examples/native_wait.ml) to capture exactly one pane and
wait until its ordinary screen contains the supplied text. The example imports
the installed Eio client, owns its switch, uses an explicit socket, closes its
client and prints the matched pane ID. It requires an existing daemon and one
pane; absence and ambiguity remain errors.

`Client.wait_for_text` first subscribes, then captures the screen immediately.
Output invalidates that observation. Queued Data events are coalesced before
the next bounded capture; a queued Gap stops that coalescing. Membership and
overflow gaps cause fresh graph acquisition and subscription in the same
connection binding. A disconnected daemon or stream fails the wait.

Success returns a captured screen containing the text. Text that appears and
disappears between captures may be missed. Deadlines are checked between
acquisitions, whose in-flight I/O keeps the client's exchange timeout. A timed
out wait does not prove that text was absent in the past.

Use `Client.subscribe` and `Subscription.next` for future output bytes. Data
retains every byte, including NUL and invalid UTF-8. Its cursor records a local
subscription generation and an observed byte offset. A cursor is neither a
snapshot timestamp nor a server-side history position. `poll` only removes a
queued event and performs no I/O.

`Subscription.wait_for_bytes` consumes those future events and matches across
event boundaries. Its nonempty pattern is limited to 64 KiB. It returns the
match's end cursor, possibly inside the last consumed Data event. A deadline
leaves the subscription active. A Gap returns `Output.Ended reason`; later
matching requires an explicit fresh capture and new subscription.

The defaults are 1 MiB and 1024 queued events per subscriber, at most 16 active
subscribers, and eight total client lanes including command/wait lanes. Reuse
one verified lane per covered session. Admission reserves bytes against the
shared 32 MiB budget. A full queue produces Gap then End rather than blocking
another subscriber or an independent command. Unknown loss uses `None`.

Coverage uses an observed session/window context and revalidates it during
admission. Layout or membership changes end continuity conservatively. Detaching
a stream leaves the primary client usable; a daemon replacement retires the
whole binding. New coverage always has a new subscription generation.

Eio readers belong to the client, use no application callbacks and keep running
when a subscriber stalls. The blocking backend advances all stream lanes during
`Subscription.next`. Cancellation closes the affected subscription and
propagates through the backend's cancellation mechanism. Client close releases
all owned lanes and retains terminal events; it leaves the daemon alive.

Neither interface establishes an atomic capture/stream barrier or reconstructs
terminal history. An immutable snapshot remains a separate captured value.

[First use](getting-started.md) · [Control and recovery](control.md) ·
[API](api.md) · [Guide](README.md)
