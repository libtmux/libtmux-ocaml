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

**libtmux-unix · blocking Linux client**

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ocaml/)

</div>

Capture a tmux graph, run commands and keep their outcomes with
[`Libtmux_unix.Client.t`][client]. Calls block the calling thread; another
domain or thread can cancel them.

[API](https://libtmux.org/en/ocaml/latest/reference/libtmux_unix/) ·
[Examples](#capture-once-traverse-after-closing) ·
[Operations and recovery](../docs/control.md) ·
[Compatibility](../docs/compatibility.md) · [Eio alternative](../eio/)

## Install and link

Not on opam yet: follow the [source install](../README.md#install-from-source)
and run the commands below from the checkout root.

In your own project, set `(lang dune 3.24)` in `dune-project`, copy the example
as `native_graph.ml` and use this `dune` file:

```dune
(executable
 (name native_graph)
 (libraries libtmux libtmux-unix))
```

Needs Linux, tmux 3.3a or newer and a local daemon.
[`Client.connect`][connect] attaches to an existing daemon;
[workspace bootstrap](../docs/workspaces.md) starts a missing one.
More: [compatibility](../docs/compatibility.md).

## Capture once, traverse after closing

### [`Client.capture`][capture]: sessions, window links and panes

The program calls [`Client.capture`][capture], then [`Client.close`][close],
then walks the snapshot. It takes a tmux binary and a socket path:

<!-- example: examples/native_graph.ml -->

```ocaml
open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let print_graph snapshot =
  Snapshot.sessions snapshot
  |> Iarray.iter (fun session ->
      Printf.printf "session %s %S\n"
        (Session.Id.to_string (Session.id session))
        (Session.name session);
      Session.window_links session
      |> Iarray.iter (fun link ->
          let window = Window_link.window link in
          Printf.printf "  window %s at %d %S\n"
            (Window.Id.to_string (Window.id window))
            (Window_link.index link) (Window.name window);
          Window.panes window
          |> Iarray.iter (fun pane ->
              Printf.printf "    pane %s active=%b %dx%d %S\n"
                (Pane.Id.to_string (Pane.id pane))
                (Pane.active pane) (Pane.width pane) (Pane.height pane)
                (Pane.current_command pane))))

let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: native_graph TMUX_BINARY SOCKET_PATH";
    exit 2);
  let client =
    get
      (Client.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2)))
  in
  let snapshot =
    Fun.protect
      ~finally:(fun () -> get (Client.close client))
      (fun () -> get (Client.capture client))
  in
  print_graph snapshot
```

[`Session.window_links`][window-links] keeps each session's own indexes.
[`Window.panes`][panes] and every other captured accessor do no I/O.
More: [graph guide](../docs/graph.md), [query guide](../docs/queries.md).

[`showcase_graph.ml`](../examples/showcase_graph.ml) runs the same capture on a
private server it starts and removes:

```console
$ opam exec -- dune exec examples/showcase_graph.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-showcase-0cd3a1/server
linked/0 linked-home: 1 pane(s)
linked/7 editor: 1 pane(s)
showcase/0 editor: 1 pane(s)
graph: 2 sessions, 2 windows, 3 links, 2 panes
```

## Cancellation and partial effects

### [`Cancellation.with_`][cancellation]: cancel a blocking call

Pass the token from [`Cancellation.with_`][cancellation] to any operation that
takes `~cancel`. A cancelled call raises `Cancellation.Cancelled`. Mutations
already written still take effect; the call drains them before raising.

- Keep the result of [`Client.submit`][submit] outside the cancelled scope,
  then inspect or await the retained operation.
- Expected failures return `result`; format them with `Error.pp`.
- A caller-owned `Cleanup` report keeps secondary teardown failures.
- A client belongs to its creating domain and a target to its connection.
  Nothing reconnects or retries for you.

More: [operations and recovery](../docs/control.md),
[recovery walkthrough](../docs/recovery.md).

[Examples](../docs/showcases.md) · [Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-t/
[connect]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-connect/
[capture]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-capture/
[close]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-close/
[window-links]: https://libtmux.org/en/ocaml/latest/reference/libtmux-session-window_links/
[panes]: https://libtmux.org/en/ocaml/latest/reference/libtmux-window-panes/
[cancellation]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-cancellation-with_/
[submit]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-submit/
