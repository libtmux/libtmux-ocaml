<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../docs/assets/logo.svg" type="image/svg+xml">
    <img src="../docs/assets/logo-512.png" width="128" height="128" alt="libtmux for OCaml">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for OCaml

**libtmux-eio · concurrent Linux client**

</div>

Use [`Libtmux_eio.Client.t`][client] for concurrent commands, retained operation
outcomes, and bounded future-output subscriptions. Your application supplies
the Eio scheduler, switch, process manager and clock.

[API](https://libtmux.org/en/ocaml/latest/reference/libtmux_eio/) ·
[Examples](#subscribe-send-literal-text-await-output) ·
[Streaming](../docs/streaming.md) ·
[Recovery](../docs/recovery.md) · [Compatibility](../docs/compatibility.md)

## Install and link

Use the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2**. There is no opam release yet. That route installs this
workspace's packages and activates the local switch; run the commands below
from the checkout root.

In a separate application, create `dune-project` containing `(lang dune 3.24)`.
Copy the example as `native_watch.ml` and use this `dune` file:

```dune
(executable
 (name native_watch)
 (libraries libtmux libtmux-eio eio_main))
```

The source installation includes Eio 1.6 and the application's `eio_main`
entry point. Native connections require Linux pidfds, tmux 3.3a–3.8, and
the daemon's PID namespace and local filesystem. See compatibility for exact
qualified releases and the remaining intensive-observation limits.

## Subscribe, send literal text, await output

### [`Client.subscribe`][subscribe]: subscribe before sending input

Create an isolated daemon with a `cat` pane. These commands address only the
new private socket and clear inherited tmux context:

```console
$ export LIBTMUX_EIO_DEMO_DIR="$(mktemp -d -t libtmux-ocaml-eio-demo.XXXXXX)"
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_EIO_DEMO_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s demo \
    -- "exec cat"
```

The example calls [`Client.subscribe`][subscribe] before
[`Client.send_text`][send-text]. [`Subscription.wait_for_bytes`][wait-for-bytes]
and the send run as concurrent fibers; [`Client.wait_for_text`][wait-for-text]
then checks the rendered screen separately.

```console
$ opam exec -- dune exec examples/native_watch.exe -- \
    tmux "$LIBTMUX_EIO_DEMO_DIR/server" %0 'ready; $HOME stays literal'
```

It prints `future_match_offset=...` with a positive byte offset, followed by
`rendered_pane=%0`. The offset depends on the bytes tmux emits. Here is the
complete program, including its scheduler and resource cleanup:

<!-- example: examples/native_watch.ml -->

```ocaml
open Libtmux
module Client = Libtmux_eio.Client
module Subscription = Libtmux_eio.Subscription

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let send_and_observe client pane ~text =
  let subscription =
    get
      (Client.subscribe ~capacity_bytes:(256 * 1024) ~capacity_events:256 client
         pane)
  in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> get (Subscription.close subscription)))
    (fun () ->
      let cursor, () =
        Eio.Fiber.pair
          (fun () ->
            match
              Subscription.wait_for_bytes ~timeout:0.5 subscription ~text
            with
            | Ok cursor -> cursor
            | Error (Output.Failure error) ->
                failwith (Format.asprintf "%a" Error.pp error)
            | Error (Output.Ended reason) ->
                failwith (Format.asprintf "%a" Output.reason_pp reason))
          (fun () ->
            get (Client.send_text client (Pane.target pane) ~text);
            get (Client.send_keys client (Pane.target pane) [ Key.Enter ]))
      in
      let rendered =
        get (Client.wait_for_text ~timeout:0.5 client pane ~text)
      in
      (cursor, rendered))

let () =
  if Array.length Sys.argv <> 5 then (
    prerr_endline "usage: native_watch TMUX_BINARY SOCKET_PATH PANE_ID TEXT";
    exit 2);
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let client =
            get
              (Client.connect ~sw ~binary:Sys.argv.(1)
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          Fun.protect
            ~finally:(fun () ->
              Eio.Cancel.protect (fun () -> get (Client.close client)))
            (fun () ->
              let snapshot = get (Client.capture client) in
              let id = get (Pane.Id.of_string Sys.argv.(3)) in
              let pane =
                match Snapshot.find_pane snapshot id with
                | Some pane -> pane
                | None -> failwith "requested pane is absent from the capture"
              in
              let cursor, rendered =
                send_and_observe client pane ~text:Sys.argv.(4)
              in
              Printf.printf "future_match_offset=%Ld\nrendered_pane=%s\n"
                cursor.offset
                (Pane.Id.to_string rendered.pane))))
```

## Choose the completion guarantee

| Task | Surface | What completion establishes |
| --- | --- | --- |
| Capture current values | [`Client.capture`][capture] | A validated graph captured over an interval |
| Retain a mutation outcome | [`Client.submit`][submit], then [`Client.await`][await] | A retained command result or explicit uncertainty |
| Match future bytes | [`Subscription.wait_for_bytes`][wait-for-bytes] | Matching bytes within continuous subscribed coverage |
| Match visible screen text | [`Client.wait_for_text`][wait-for-text] | A later rendered capture contains the text |

Cancellation propagates through Eio. Cancelling an awaiting fiber does not undo
written commands; retain submitted handles outside that fiber when recovery
matters. The [recovery example](../examples/native_recovery.ml) demonstrates this.

Subscriptions expose `Data`, `Gap` and `End`. A gap requires fresh observation
and resubscription when continuing coverage; a new capture cannot restore lost
historical output. Queues and admission are bounded. Stream readers do not wait
for slow consumers, and live handles remain on their creating domain.

The [pure core](../lib/) can inspect captured snapshots without Eio. The
[blocking backend](../unix/) is available for scripts that do not need fibers.

## Clean up

Remove the demonstration session and its socket directory. Closing a library
client releases its resources; it does not send a daemon shutdown command.

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_EIO_DEMO_DIR/server" \
    kill-session \
    -t '=demo'
```

```console
$ rm -f -- "$LIBTMUX_EIO_DEMO_DIR/server"
```

```console
$ rmdir "$LIBTMUX_EIO_DEMO_DIR"
```

[Operations](../docs/control.md) · [Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-t/
[subscribe]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-subscribe/
[send-text]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-send_text/
[wait-for-bytes]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-subscription-wait_for_bytes/
[wait-for-text]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-wait_for_text/
[capture]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-capture/
[submit]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-submit/
[await]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-await/
