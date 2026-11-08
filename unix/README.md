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

</div>

Capture a tmux graph, run targeted commands, and retain operation outcomes with
`Libtmux_unix`. Calls block the invoking thread. Scoped cancellation can be
signalled from another domain or system thread.

[API](libtmux_unix.mli) · [Operations and recovery](../docs/control.md) ·
[Compatibility](../docs/compatibility.md) · [Eio alternative](../eio/)

## Install and link

Use the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2**. There is no opam release yet. That route installs this
workspace's packages and activates the local switch; run the commands below
from the checkout root.

In a separate application, create `dune-project` containing `(lang dune 3.24)`.
Copy the example as `native_graph.ml` and use this `dune` file:

```dune
(executable
 (name native_graph)
 (libraries libtmux libtmux-unix))
```

Native connections require Linux pidfds, tmux 3.3a–3.8, and the daemon's
PID namespace and local filesystem. Ordinary `Client.connect` attaches to an
existing daemon; [workspace bootstrap](../docs/workspaces.md) creates a missing
endpoint explicitly. See the compatibility guide for exact tested releases and
workload limits.

## Capture once, traverse after closing

Create an isolated daemon with a `cat` pane. These commands address only the
new private socket and clear inherited tmux context:

```console
$ export LIBTMUX_UNIX_DEMO_DIR="$(mktemp -d -t libtmux-ocaml-unix-demo.XXXXXX)"
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_UNIX_DEMO_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s demo \
    -- "exec cat"
```

```console
$ opam exec -- dune exec examples/native_graph.exe -- \
    tmux "$LIBTMUX_UNIX_DEMO_DIR/server"
```

The output starts with `session $0 "demo"` and lists its window link and pane
`%0`. The complete program closes the client before traversing the snapshot:

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

`Session.window_links` preserves session-specific indexes. `Window.panes` and
all other captured accessors perform no I/O. See the [graph guide](../docs/graph.md)
for windows shared between sessions and the [query guide](../docs/queries.md)
for native predicates, typed expressions and exact cardinality.

## Cancellation and partial effects

Use `Cancellation.with_` for scoped cancellation, passing its token to operations
that accept `~cancel`. Cancellation raises `Cancellation.Cancelled`; it does not
mean an already written mutation had no effect. Written work drains before the
awaiting call raises, within the documented transport deadline and local I/O
completion limits.

For recoverable mutations, keep the result of `Client.submit` outside the
cancelled scope, then inspect or await the retained operation. Expected failures
return `result`; `Error.pp` formats them. A caller-owned `Cleanup` report retains
secondary teardown failures. [Recovery](../docs/recovery.md) explains the same
retained-operation model through a complete Eio example.

Live clients belong to their creating domain. Mutation targets are bound to the
connection generation; the library does not reconnect or retry them automatically.

## Clean up

Remove the demonstration session and its socket directory. Closing a library
client releases its resources; it does not send a daemon shutdown command.

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_UNIX_DEMO_DIR/server" \
    kill-session \
    -t '=demo'
```

```console
$ rm -f -- "$LIBTMUX_UNIX_DEMO_DIR/server"
```

```console
$ rmdir "$LIBTMUX_UNIX_DEMO_DIR"
```

[Examples](../docs/showcases.md) · [Changelog](CHANGELOG.md) · [MIT](../LICENSE)
