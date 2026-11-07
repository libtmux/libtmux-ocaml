# libtmux-ocaml

Drive tmux from OCaml: create sessions and panes, capture an immutable graph,
query it locally, and observe output through Eio or a blocking client.

[Guide](docs/README.md) · [API](docs/api.md) ·
[Examples](examples) · [Compatibility](docs/compatibility.md) ·
[CI](https://github.com/libtmux/libtmux-ocaml/actions/workflows/ocaml.yml)

Targets **OCaml 5.5.2 on Linux**. Native checks cover tmux 3.3, 3.3a, 3.4 and
3.8. Connections require Linux pidfds and the daemon's PID namespace and local
filesystem. The pure model and queries use the standard library.

## Install from source

There is no opam release yet. With [opam](https://opam.ocaml.org/doc/Install.html)
initialized and tmux installed, clone this repository:

```console
$ git clone https://github.com/libtmux/libtmux-ocaml.git
```

```console
$ cd libtmux-ocaml
```

Create a local compiler switch; this leaves the global switch unchanged:

```console
$ opam switch create \
    --deps-only \
    --no-switch \
    . ocaml-base-compiler.5.5.2
```

Install the libraries and the Eio entry point used by the examples:

```console
$ opam install . eio_main.1.6
```

Activate this switch in the current shell before using another Dune project:

```console
$ eval "$(opam env --switch=. --set-switch)"
```

The [installation guide](docs/getting-started.md) shows how to use the installed
packages in a separate Dune project.

## Read a real tmux graph

Create an isolated demonstration server. These commands clear inherited tmux
context and use a private socket, so the examples do not select your usual server.

```console
$ export LIBTMUX_DEMO_DIR="$(mktemp -d -t libtmux-ocaml-demo.XXXXXX)"
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s demo \
    -- "exec cat"
```

Print its sessions, window links and panes:

```console
$ opam exec -- dune exec examples/native_graph.exe -- \
    tmux "$LIBTMUX_DEMO_DIR/server"
```

This is the complete [program](examples/native_graph.ml). It closes the client
before traversing the captured graph:

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

A window can belong to several sessions. `Window_link.index` belongs to a
session/window link; `Window.t` identifies the shared window. The
[graph guide](docs/graph.md) demonstrates linking one window twice without
losing either context.

## Filter captured values

Use ordinary functions first. This performs no tmux I/O:

<!-- example: examples/native_query.ml#native-filter -->

```ocaml
let active_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
  |> Seq.map Pane.id |> List.of_seq
```

Use typed expressions when a query needs inspection, serialization or reuse:

<!-- example: examples/native_query.ml#typed-filter -->

```ocaml
let roomy_terminals : Pane.t Expr.t =
  Expr.all
    [
      Expr.Bool.is_true Pane.Fields.active;
      Expr.Text.is_in Pane.Fields.current_command
        [ "cat"; "bash"; "zsh"; "nvim" ];
      Expr.Int.ge Pane.Fields.width 80;
    ]

let roomy_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq
  |> Query.matching roomy_terminals
  |> Seq.map Pane.id |> List.of_seq
```

A text operator on `Pane.Fields.width`, or a session filter applied to panes,
fails to type-check. Results use `Iarray`, `Seq` and `List`. Matching preserves
input order and duplicates; local accessors stay readable after client closure.

Run the [complete query program](examples/native_query.ml) against the demo:

```console
$ opam exec -- dune exec examples/native_query.exe -- \
    tmux "$LIBTMUX_DEMO_DIR/server"
```

The [query guide](docs/queries.md) covers relationship quantifiers, empty
relations, exact cardinality and explicit acquisition with source filtering.

## Create a session and split its panes

The [layout program](examples/native_build.ml) creates an `editor` window with
two panes and a separate `logs` window. It sets a working directory, passes an
environment value, and assigns an option and pane title:

<!-- example: examples/native_build.ml#create-layout -->

```ocaml
let build client ~name ~directory =
  let spawn =
    Spawn.make ~cwd:directory
      ~environment:[ ("LIBTMUX_PROJECT", name) ]
      (Spawn.Exec { program = "cat"; args = [] })
  in
  let session =
    get (Client.create_session client ~name ~window_name:"editor" ~spawn ())
  in
  let right =
    get (Client.split_pane client session.pane ~direction:Geometry.Right ~spawn)
  in
  let logs =
    get (Client.create_window client session.session ~name:"logs" ~spawn)
  in
  get (Client.set_pane_title client right.pane ~title:"build output");
  get
    (Client.set_option client (Options.Session session.session) ~name:"@project"
       (Options.Text name));
  (session, right, logs)
```

```console
$ opam exec -- dune exec examples/native_build.exe -- \
    tmux "$LIBTMUX_DEMO_DIR/server" project "$LIBTMUX_DEMO_DIR"
```

It prints the IDs tmux returned. Existing session names fail instead of replacing
resources. Mutations receive generation-bound targets; selecting a value does
not make a later mutation atomic. [Operations and recovery](docs/control.md)
explains acknowledgement, completion and uncertain outcomes.

## Send literal input and observe the reply with Eio

The [Eio program](examples/native_watch.ml) subscribes before sending text,
awaits future bytes concurrently with the send, then checks the rendered screen:

```console
$ opam exec -- dune exec examples/native_watch.exe -- \
    tmux "$LIBTMUX_DEMO_DIR/server" %0 'ready; $HOME stays literal'
```

It sends the string to the demo's `cat` pane and explicitly presses Enter.
`send_text` does not interpret shell syntax. The application owns `Eio_main`
and its switch; the library never starts a scheduler.

Subscriptions report `Data`, `Gap` and `End` through bounded queues. A slow
subscriber cannot block another subscriber or the command lane. Future-byte
matching and rendered-screen waits have different contracts; neither supplies
terminal history or an atomic capture/stream barrier. See
[streaming and cancellation](docs/streaming.md).

## Packages and current limits

| Dune library | Module | Use |
| --- | --- | --- |
| `libtmux` | `Libtmux` | Immutable graph, typed fields/relations, expressions and cardinality |
| `libtmux-unix` | `Libtmux_unix` | Blocking Linux client and scoped cancellation |
| `libtmux-eio` | `Libtmux_eio` | Eio client, retained operations and subscriptions |
| `libtmux-json` | `Libtmux_json` | Bounded query and workspace JSON decoding |
| `libtmux-workspace` | `Libtmux_workspace` | Validated workspace configuration, plans and execution journals |

Workspace delivery is in progress; the installed workspace CLI and MCP service
are unfinished. There is no runnable MCP server to configure yet. See
[status and adoption gaps](docs/status.md) before choosing this checkout for a
complete automation suite. macOS, Windows, remote-daemon binding and Java regex
evaluation are outside the current support contract.

[API documentation](docs/api.md) comes from the public `.mli` files using odoc.
The [testing guide](docs/testing.md) explains typed Alcotest assertions,
ppx_expect diagnostics, QCheck properties, installed examples and cached tmux
builds. [Benchmarks](docs/benchmarking.md) provide a reproducible same-graph
blocking/Eio capture harness. [Compatibility](docs/compatibility.md) records
component-level evidence.

## Clean up the demo

Remove only the two sessions created above; closing a library client leaves
the daemon running:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/server" \
    kill-session -t '=project'
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/server" \
    kill-session -t '=demo'
```

```console
$ rm -f -- "$LIBTMUX_DEMO_DIR/server"
```

```console
$ rmdir "$LIBTMUX_DEMO_DIR"
```

For development, read [CONTRIBUTING.md](.github/CONTRIBUTING.md).
Licensed under [MIT](LICENSE).
