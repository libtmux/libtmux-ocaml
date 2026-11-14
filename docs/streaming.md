# Observe output and wait for rendered text

- [native_watch.ml](../examples/native_watch.ml): a concurrent literal send,
  future-byte match and rendered-screen check. Your application owns the Eio
  scheduler and switch.
- [native_wait.ml](../examples/native_wait.ml): capture exactly one pane and
  wait until its screen contains the text. It needs an existing daemon and one
  pane; absence and ambiguity are errors.

`Client.wait_for_text` first subscribes, then captures the screen immediately.
Output invalidates that observation. Queued Data events are coalesced before
the next bounded capture; a queued Gap stops that coalescing. Membership and
overflow gaps cause fresh graph acquisition and subscription in the same
connection binding. A disconnected daemon or stream fails the wait.

Success returns a captured screen containing the text. Text that appears and
disappears between captures may be missed. Deadlines are checked between
acquisitions, whose in-flight I/O keeps the client's exchange timeout. A timed
out wait does not prove that text was absent in the past.

The wait releases its temporary subscription on every exit. An earlier error or
cancellation remains the primary result; `Client.cleanup` retains secondary
cleanup failures. If cleanup fails after a match or during gap recovery, the
wait fails instead of reporting success or opening another subscription.

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
another subscriber or an independent command. Unknown loss has no byte count.
These limits apply together; [plan shared capacity](#plan-shared-capacity)
before combining many observers with captures and reads.

Coverage uses an observed session/window context and revalidates it during
admission. Layout or membership changes end continuity conservatively. Detaching
a stream leaves the primary client usable; a daemon replacement retires the
whole binding. New coverage always has a new subscription generation.

Eio readers belong to the client, use no application callbacks and keep running
when a subscriber stalls. The blocking backend advances all stream lanes during
`Subscription.next`. Cancellation closes the affected subscription and
propagates through the backend's cancellation mechanism. Client close releases
all owned lanes and retains terminal events; it leaves the daemon alive.

When a subscription releases the last user of a lane, close waits for its
owned helper to be reaped. Concurrent Eio subscription closes join that same
cleanup. Repeated closes preserve the first terminal reason and any cleanup
failure; unconsumed terminal events remain readable through `Subscription.poll`.

The [recovery program](recovery.md) shows how to cancel one operation waiter
while keeping its retained outcome available. Cancelling a subscription closes
that subscription; it does not cancel an already admitted command.

Neither interface establishes an atomic capture/stream barrier or reconstructs
terminal history. An immutable snapshot remains a separate captured value.

## Plan shared capacity

Every client has its own bounded payload budget and process-slot pool. The
blocking and Eio clients use the same accounting. An individually valid queue
or command can still return `Error.Capacity` when another reservation consumes
the available headroom:

| Resource | Current limit or reservation |
| --- | --- |
| Aggregate client payload | 32 MiB shared by queues, commands and operation scratch space |
| Admitted commands | 64; encoded payload accounting remains charged until completion or cancellation before writing |
| Admitted command bytes | 1 MiB shared across admitted operations; submission also temporarily reserves 2 MiB |
| Client process slots | 8, including the primary control client; each auxiliary slot reserves 128 KiB |
| Subscriptions | 16 active per client, sharing a verified stream lane per covered session |
| Subscriber queue | 1 MiB / 1024 events by default; reserve the full configured byte capacity even when empty |
| Graph or rendered capture | 16 MiB operation scratch reservation plus an 8 MiB control exchange |
| Option, environment or hook read | 16 MiB scratch reservation plus a temporary process slot |

The payload budget tracks library reservations. Caller-retained snapshots,
completed operation handles, receipts and exception payloads have their own
lifetimes, alongside runtime overhead, child-process memory and tmux's
allocations. See [observation retention](graph.md).

For example, sixteen default queues on one covered session reserve 16 MiB
plus that session's auxiliary slot. A subsequent capture or read cannot obtain
its scratch reservation. Even eight default queues leave insufficient room for
the capture's nested control exchange. Closing subscriptions releases their
reservations; the client remains usable after a capacity error.

| Empty queues, one covered session | Capture | Option read |
| --- | --- | --- |
| 16 × 1 MiB | `Capacity` | `Capacity` |
| 8 × 1 MiB | `Capacity` | Fits the reservation budget |
| 7 × 1 MiB | Fits the reservation budget | Fits the reservation budget |
| 16 × 256 KiB | Fits the reservation budget | Fits the reservation budget |

These examples describe reservation accounting on a fixed one-pane graph.
Additional lanes, admitted commands and concurrent work consume more headroom.
A budget that fits still needs valid targets, available data and a responsive
daemon.

The [complete watcher](../examples/native_watch.ml) chooses its queue explicitly:

<!-- example: examples/native_watch.ml#bounded-subscription -->

```ocaml
let subscription =
  get
    (Client.subscribe ~capacity_bytes:(256 * 1024) ~capacity_events:256 client
       pane)
```

Its full program includes the client, pane acquisition, result handling, Eio
switch and cleanup. Choose a capacity for the burst your application can
consume; a smaller queue reaches `Gap Overflow` sooner when its reader stalls.

Slots need their own headroom. The primary client and seven distinct covered
sessions fill all eight slots, leaving none for a read process or `wait_for`.
If an application needs those operations, it can cap distinct covered sessions
at six while keeping one slot for service, accounting for any waits already
using slots. The library currently reserves no slot exclusively for service.
Several panes in the same session can share its stream lane.

Reducing queue capacities does not free process slots. Closing the last active
subscriber for a covered session releases its lane after owned-helper cleanup.
A separate client has its own budget and slots, but also its own source
generation: acquire observations on that client before using its targets.

## Recover after a gap

Close the ended subscription, capture the graph again, and establish fresh
coverage for the observed pane. This recovers future observation. Bytes lost
before the new subscription are still unavailable; a screen capture cannot
reconstruct their history.

The [complete recovery program](../examples/native_stream_recovery.ml) creates
a window running `cat`, observes a reply, then splits the window to trigger a
membership gap. It handles that gap, removes the extra pane and closes the old
subscription. It captures the original pane again, subscribes, and observes
new input with a different cursor generation:

<!-- example: examples/native_stream_recovery.ml#recover-coverage -->

```ocaml
let recover_coverage client id (previous : Output.cursor) =
  let fresh = capture_pane client id in
  let after =
    with_subscription client fresh (fun subscription ->
        echo client fresh subscription "after-gap")
  in
  if Generation.equal previous.generation after.generation then
    failwith "new subscription reused the old cursor generation";
  print_endline "coverage=fresh; cursor-generation=new; future=after-gap"
```

The source contains the imports, scheduler, cleanup and matching helpers.
`capture_pane` fails if the pane disappeared. `with_subscription` admits coverage
before `echo` sends input and awaits its reply concurrently. The
example never reconnects, reuses an old cursor or retries an uncertain mutation.
It removes only panes whose creation returned successfully, leaving any foreign
panes untouched. Primary exceptions survive secondary cleanup failures.

Creation here uses convenience calls. Cancellation before one returns can leave
a creation whose ID the caller never received. For creation outcomes that must
survive waiter cancellation, retain `Client.submit`'s handle before `Client.await`,
as shown in [operation recovery](recovery.md). An uncertain outcome does not
authorize a retry or deletion of an unproven resource.

After [installing from source](getting-started.md), run this walkthrough from
the clone. Create a private seed session:

```console
$ export LIBTMUX_STREAM_RECOVERY_DIR="$(mktemp -d -t libtmux-ocaml-stream-recovery.XXXXXX)"
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_STREAM_RECOVERY_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s stream-demo \
    -- "exec cat"
```

Run the program against the seed session's literal `$0` ID:

```console
$ opam exec -- dune exec examples/native_stream_recovery.exe -- \
    tmux "$LIBTMUX_STREAM_RECOVERY_DIR/server" '$0'
```

Expected output is `gap=membership-changed; history=unavailable`, followed by
`coverage=fresh; cursor-generation=new; future=after-gap`. The seed session
remains, with no additional panes or clients. Remove that session and directory:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_STREAM_RECOVERY_DIR/server" \
    kill-session \
    -t '=stream-demo'
```

```console
$ rm -f -- "$LIBTMUX_STREAM_RECOVERY_DIR/server"
```

```console
$ rmdir "$LIBTMUX_STREAM_RECOVERY_DIR"
```

This exercise uses a stable private daemon and a deliberate layout change.
Transport loss, repeated membership changes or a missing pane can prevent fresh
coverage. Preserve those failures and choose the next action explicitly.

[First use](getting-started.md) · [Control and recovery](control.md) ·
[API](api.md) · [Guide](README.md)
