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

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ocaml/)

</div>

Run concurrent commands, keep their outcomes and watch future output with
[`Libtmux_eio.Client.t`][client]. Your application owns the Eio scheduler,
switch, process manager and clock.

[API](https://libtmux.org/en/ocaml/latest/reference/libtmux_eio/) ·
[Examples](#subscribe-send-literal-text-await-output) ·
[Streaming](../docs/streaming.md) ·
[Recovery](../docs/recovery.md) · [Compatibility](../docs/compatibility.md)

## Install and link

Not on opam yet: follow the [source install](../README.md#install-from-source)
and run the commands below from the checkout root.

In your own project, set `(lang dune 3.24)` in `dune-project`, copy the example
as `native_watch.ml` and use this `dune` file:

```dune
(executable
 (name native_watch)
 (libraries libtmux libtmux-eio eio_main))
```

The source install includes Eio and `eio_main`. Needs Linux, tmux 3.3a or
newer and a local daemon. More: [compatibility](../docs/compatibility.md).

## Subscribe, send literal text, await output

### [`Client.subscribe`][subscribe]: subscribe before sending input

Start a private daemon with a `cat` pane, away from your own tmux server:

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

It prints `future_match_offset=` with a positive byte offset, then
`rendered_pane=%0`. The complete program:

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

- Cancelling a waiting fiber does not undo written commands. Keep submitted
  handles outside that fiber ([recovery example](../examples/native_recovery.ml)).
- A subscription yields `Data`, `Gap` and `End`. After a gap, capture again and
  resubscribe; lost output cannot be recovered.
- Queues are bounded, and a slow reader never stalls the others.
- A client and its subscriptions belong to their creating domain.

More: [streaming](../docs/streaming.md). No fibers needed? Use the
[blocking client](../unix/), or the [pure core](../lib/) to inspect snapshots.

## Clean up

Remove the demo session and its socket directory. Closing a client leaves the
daemon running.

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
