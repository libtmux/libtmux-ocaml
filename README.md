<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo.png" width="128" height="128" alt="libtmux for OCaml">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for OCaml

[![OCaml](https://github.com/libtmux/libtmux-ocaml/actions/workflows/ocaml.yml/badge.svg)](https://github.com/libtmux/libtmux-ocaml/actions/workflows/ocaml.yml)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ocaml/)
[![license](https://img.shields.io/badge/license-MIT-blue)](https://github.com/libtmux/libtmux-ocaml/blob/master/LICENSE)

</div>

Drive tmux from OCaml: create [sessions][session], [windows][window] and
[panes][pane], capture an [immutable graph][snapshot], [query it locally][query],
and observe output through an [Eio][eio-client] or [blocking client][unix-client].

[Guide](https://libtmux.org/en/ocaml/latest/) ·
[API](https://libtmux.org/en/ocaml/latest/reference/) ·
[Examples](https://libtmux.org/en/ocaml/latest/guides/showcases/) ·
[Workspace CLI](cli/) ·
[Compatibility](https://libtmux.org/en/ocaml/latest/guides/compatibility/) ·
[CI](https://github.com/libtmux/libtmux-ocaml/actions/workflows/ocaml.yml)

Needs OCaml 5, Linux and tmux 3.3a or newer. The model and queries use the
standard library alone.

## Install from source

Not on opam yet. With [opam](https://opam.ocaml.org/doc/Install.html) and tmux
installed, clone the repository:

```console
$ git clone https://github.com/libtmux/libtmux-ocaml.git
```

```console
$ cd libtmux-ocaml
```

Create a local compiler switch; the global one is untouched:

```console
$ opam switch create \
    --deps-only \
    --no-switch \
    . ocaml-base-compiler.5.5.2
```

Install the libraries and the Eio entry point:

```console
$ opam install . eio_main.1.6
```

Activate the switch in this shell:

```console
$ eval "$(opam env --switch=. --set-switch)"
```

More: [installation guide](docs/getting-started.md), for use from another Dune
project.

## Start and stop a private server

### [`with_private_daemon`][unix-private-daemon]: a tmux daemon the program owns

One call starts tmux on a fresh socket in its own directory, runs your function
and then stops the daemon and removes the directory, also after an exception.
[`Libtmux_eio.with_private_daemon`][eio-private-daemon] does the same under Eio
cancellation, and [`Client.kill_server`][unix-kill-server] stops a daemon early.
The daemon starts with no session, so the
[bootstrap program](examples/showcase_bootstrap.ml) creates the first one with
[`Workspace.submit_bootstrap`][unix-bootstrap]:

<!-- example: examples/showcase_bootstrap.ml#private-daemon -->

```ocaml
let snapshot =
  get
    (Libtmux_unix.with_private_daemon ~binary (fun endpoint ->
         let execution =
           bootstrap ~binary ~version:(local_version binary)
             ~directory:(Sys.getcwd ()) endpoint
         in
         let snapshot =
           protect
             ~finally:(fun () -> get (Workspace.close execution))
             (fun () ->
               let receipt = get (Workspace.await execution) in
               require_success receipt;
               let client = Option.get (Workspace.client execution) in
               get (Client.capture client))
         in
         (match Endpoint.kind endpoint with
         | Endpoint.Socket_path socket -> Printf.printf "socket=%s\n" socket
         | Endpoint.Named_socket _ -> ());
         snapshot))
```

```console
$ opam exec -- dune exec examples/showcase_bootstrap.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-c75807/server
bootstrapped: 1 session, 1 window, 1 pane
```

Pass `~config_file` to run the daemon with your own tmux configuration, or
`~session` to start it with one session. More: [bootstrap guide](docs/bootstrap.md).

## Read a real tmux graph

### [`Client.capture`][unix-capture]: sessions, window links and panes

One program starts a private server, builds two sessions that share a window,
captures the graph and removes everything it made.
[`Client.create_session`][create-session] and [`Client.link_window`][link-window]
build the graph; [`Client.capture`][unix-capture] reads it:

<!-- example: examples/showcase_graph.ml#capture-graph -->

```ocaml
open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let capture_graph client (initial : Created.t) spawn =
  let linked =
    get
      (Client.create_session client ~name:"linked" ~window_name:"linked-home"
         ~spawn ())
  in
  let pane =
    Snapshot.find_pane
      (get (Client.capture client))
      (Pane.Target.id linked.pane)
    |> Option.get
  in
  let text = "showcase ready" in
  ignore (get (Client.wait_for_text ~timeout:0.5 client pane ~text));
  get
    (Client.link_window client initial.window ~session:linked.session ~index:7);
  get (Client.capture client)
```

```console
$ opam exec -- dune exec examples/showcase_graph.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-0cd3a1/server
linked/0 linked-home: 1 pane(s)
linked/7 editor: 1 pane(s)
showcase/0 editor: 1 pane(s)
graph: 2 sessions, 2 windows, 3 links, 2 panes
```

A window can belong to several sessions: [`Window_link.index`][window-index]
is per session, [`Window.t`][window] is shared. The
[complete program](examples/showcase_graph.ml) also starts the server and
removes its directory. More: [graph guide](docs/graph.md).

## Filter captured values

### [`Snapshot`][snapshot]: filter with native OCaml functions

Plain functions, no tmux I/O:

<!-- example: examples/native_query.ml#native-filter -->

```ocaml
open Libtmux

let active_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
  |> Seq.map Pane.id |> List.of_seq
```

### [`Query.matching`][matching]: apply an inspectable expression

An [`Expr`][expr] can be inspected, serialized and reused:

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

A text operator on `Pane.Fields.width` fails to type-check. Matching keeps
input order. The [complete query program](examples/native_query.ml) takes a tmux
binary and a socket path. More: [query guide](docs/queries.md).

### [`Plan.panes`][plan-panes]: what tmux would filter and what stays local

[`Plan.panes`][plan-panes] splits a filter into a tmux source filter and a local
remainder, without I/O. [`Plan.explanation`][plan-explanation],
[`Plan.source_filter`][plan-source-filter] and [`Plan.residual`][plan-residual]
show the split; `Require_exact` rejects a filter that cannot be lowered:

<!-- example: examples/query_plan.ml -->

```ocaml
open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let show name expression =
  let plan = get (Plan.panes expression) in
  Printf.printf "%s: %s\n" name (Plan.explanation plan);
  Printf.printf "  source filter: %s\n"
    (Option.value (Plan.source_filter plan) ~default:"nothing");
  Printf.printf "  local filter: %s\n" (Expr.describe (Plan.residual plan))

let () =
  let active : Pane.t Expr.t = Expr.Bool.is_true Pane.Fields.active in
  let editors : Pane.t Expr.t =
    Expr.all
      [ active; Expr.Text.is_in Pane.Fields.current_command [ "nvim"; "vim" ] ]
  in
  show "active" active;
  show "editors" editors;
  match Plan.panes ~pushdown:Plan.Require_exact editors with
  | Error error -> Format.printf "rejected: %a@." Error.pp error
  | Ok _ -> failwith "an inexact plan was accepted"
```

```console
$ opam exec -- dune exec examples/query_plan.exe
```

```text
active: exact pane-flag source filter; retain local evaluation
  source filter: #{==:#{pane_active},1}
  local filter: pane_active = true
editors: capture complete observations and evaluate locally
  source filter: nothing
  local filter: all [pane_active = true; pane_current_command in ["nvim"; "vim"]]
rejected: unsupported: exact pushdown supports only pane flags and Boolean composition
```

Capture clients still read the whole graph and filter locally; they do not run
plans yet. More: [query guide](docs/queries.md).

## Create a session and split its panes

### [`Client.create_session`][create-session]: start a session and build its layout

[`Client.split_pane`][split-pane] and [`Client.create_window`][create-window]
add to it; [`Spawn.make`][spawn] sets the directory, command and environment.
From the [layout program](examples/native_build.ml):

<!-- example: examples/native_build.ml#create-layout -->

```ocaml
open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

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

An existing session name fails; nothing is replaced. More:
[operations and recovery](docs/control.md).

[`showcase_layout.ml`](examples/showcase_layout.ml) splits panes and applies a
layout on a private server it starts and removes:

```console
$ opam exec -- dune exec examples/showcase_layout.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-0cd3a1/server
layout: 3 horizontal panes
```

## Send keys, read a pane and resize

### [`Client.send_text`][unix-send-text]: type into a pane, read it back and resize

[`Client.send_keys`][unix-send-keys] presses named keys,
[`Client.capture_text`][unix-capture-text] reads rows, and
[`Client.resize_pane`][unix-resize-pane] and
[`Client.resize_window`][unix-resize-window] set sizes in cells. The
[keys program](examples/showcase_send_keys.ml) splits a pane that prints
`showcase ready` and uses all four:

<!-- example: examples/showcase_send_keys.ml#pane-io -->

```ocaml
open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let find client target =
  Snapshot.find_pane (get (Client.capture client)) (Pane.Target.id target)
  |> Option.get

let wait client pane text =
  ignore (get (Client.wait_for_text ~timeout:0.5 client pane ~text))

let drive client (initial : Created.t) spawn =
  let right =
    get (Client.split_pane client initial.pane ~direction:Geometry.Right ~spawn)
  in
  let pane = find client right.pane in
  wait client pane "showcase ready";
  let text = "literal: $HOME; #{pane_id}" in
  get (Client.send_text client right.pane ~text);
  get (Client.send_keys client right.pane [ Key.Enter ]);
  wait client pane text;
  let screen = get (Client.capture_text client pane ~start:0 ~end_:1) in
  Printf.printf "sent: %s\ncaptured: %S\n" text screen.bytes;
  get (Client.resize_window client initial.window ~width:100 ~height:30);
  get (Client.resize_pane client right.pane ~width:20);
  let resized = find client right.pane in
  Printf.printf "resized: %dx%d\n" (Pane.width resized) (Pane.height resized)
```

```console
$ opam exec -- dune exec examples/showcase_send_keys.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-0cd3a1/server
sent: literal: $HOME; #{pane_id}
captured: "showcase ready\nliteral: $HOME; #{pane_id}\n"
resized: 20x30
```

`send_text` presses no Enter, and `capture_text` reads visible rows, not
scrollback. More: [operations](docs/operations.md), including
[`kill_pane`][unix-kill-pane], [`kill_window`][unix-kill-window],
[`kill_session`][unix-kill-session], [`read_option`][unix-read-option] and
[`set_hook`][unix-set-hook].

## Change settings, rearrange panes and steer clients

### [`Client.set_option`][unix-set-option]: options, environment and hooks

[`Client.set_environment`][unix-set-environment] and
[`Client.set_hook`][unix-set-hook] take the same scopes. Each has a matching
`unset_*`, `read_*` and `capture_*` call. The
[options program](examples/showcase_options.ml) sets, reads and removes a server
option, an environment variable and a hook:

<!-- example: examples/showcase_options.ml#options-and-environment -->

```ocaml
let integer client scope name =
  match get (Client.read_option client scope name) with
  | Some (Options.Scalar (Options.Integer value)) -> Int64.to_int value
  | _ -> failwith (name ^ " is not an integer")

let tune_options client (initial : Created.t) =
  let server = Options.Server and session = Options.Session initial.session in
  get
    (Client.set_option client server ~name:"escape-time" (Options.Integer 13L));
  assert (integer client server "escape-time" = 13);
  (* Unsetting restores tmux's default, which differs between releases. *)
  get (Client.unset_option client server "escape-time");
  assert (integer client server "escape-time" <> 13);
  let name = "@project" in
  get (Client.set_option client session ~name (Options.Text "ocaml"));
  assert (
    Options.lookup (get (Client.capture_options client session)) name <> None);
  get (Client.clear_option_array client server "command-alias")

let tune_environment client =
  let global = Environment.Global and name = "LIBTMUX_DEMO" in
  let lookup () =
    Environment.lookup (get (Client.capture_environment client global)) name
  in
  get (Client.set_environment client global ~name "one");
  assert (lookup () = Some (Environment.Value "one"));
  (* A removal marker masks a global value; unsetting drops the entry. *)
  get (Client.remove_environment client global name);
  assert (lookup () = Some Environment.Removed);
  get (Client.unset_environment client global name);
  assert (lookup () = None)
```

```console
$ opam exec -- dune exec examples/showcase_options.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-3f9a1c/server
configured: options, hooks and environment
```

[`Client.remove_environment`][unix-remove-environment] stores a marker that
masks a global value; unsetting drops the entry. More: [options](docs/options.md).

### [`Client.swap_panes`][unix-swap-panes]: swap, zoom, move and break panes

[`Client.rotate_panes`][unix-rotate-panes], [`Client.zoom_pane`][unix-zoom-pane],
[`Client.move_pane`][unix-move-pane] and [`Client.break_pane`][unix-break-pane]
change a window's arrangement; the [panes program](examples/showcase_panes.ml)
also respawns a pane and clears its history:

<!-- example: examples/showcase_panes.ml#arrange-panes -->

```ocaml
let find client target =
  Snapshot.find_pane (get (Client.capture client)) (Pane.Target.id target)
  |> Option.get

let panes_in client (window : Window.target) =
  Window.panes
    (Snapshot.find_window
       (get (Client.capture client))
       (Window.Target.id window)
    |> Option.get)

let arrange client (initial : Created.t) spawn =
  let right =
    get (Client.split_pane client initial.pane ~direction:Geometry.Right ~spawn)
  in
  let below =
    get (Client.split_pane client right.pane ~direction:Geometry.Below ~spawn)
  in
  assert (Iarray.length (panes_in client initial.window) = 3);
  (* Swap two panes, rotate all three and choose the active one. *)
  let left target = Pane.left (find client target) in
  let before = left initial.pane in
  get (Client.swap_panes client initial.pane right.pane);
  assert (left initial.pane <> before);
  get (Client.rotate_panes client initial.window `Forward);
  get (Client.select_pane client right.pane);
  assert (Pane.active (find client right.pane));
  (* Zoom one pane over the window, restore it and cycle the layout. *)
  get (Client.zoom_pane client right.pane);
  let zoomed = find client right.pane in
  assert (Pane.width zoomed = Window.width (Pane.window zoomed));
  get (Client.zoom_pane client right.pane);
  get (Client.cycle_layout client initial.window `Next);
  (* Move a pane beside another, then break it into a new window. *)
  get
    (Client.move_pane client below.pane ~beside:initial.pane
       ~direction:Geometry.Below);
  let broken =
    get
      (Client.break_pane client below.pane ~name:"broken"
         ~session:initial.session ~index:5)
  in
  assert (broken.window_index = 5);
  assert (Iarray.length (panes_in client initial.window) = 2)
```

```console
$ opam exec -- dune exec examples/showcase_panes.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-8d2e47/server
arranged: swap, rotate, zoom, cycle, move, break, respawn
```

tmux can constrain geometry; capture again to read the result.

### [`Client.switch_client_at`][unix-switch-client]: steer another client

A function ending in `_at` addresses the client bearing a name when the command
runs. The [clients program](examples/showcase_clients.ml) steers a second
control client with
[`Client.resize_control_client_at`][unix-resize-control-client],
[`Client.refresh_client_at`][unix-refresh-client] and
[`Client.request_detach_client_at`][unix-detach-client]:

<!-- example: examples/showcase_clients.ml#steer-client -->

```ocaml
let same a b = Client_name.to_string a = Client_name.to_string b

let names client =
  Snapshot.clients (get (Client.capture client))
  |> Iarray.to_list
  |> List.map Client_observation.current_name

let observed client name =
  Snapshot.clients (get (Client.capture client))
  |> Iarray.to_seq
  |> Seq.find (fun observation ->
      same (Client_observation.current_name observation) name)

(* A second control client is the one this program steers. *)
let connect_second ~binary client =
  let before = names client in
  let second =
    get (Client.connect ~binary (Source.endpoint (Client.source client)))
  in
  let name =
    List.find (fun name -> not (List.exists (same name) before)) (names client)
  in
  (second, name)

let steer client name (other : Created.t) =
  get (Client.resize_control_client_at client name ~width:100 ~height:30);
  get (Client.refresh_client_at client name);
  get (Client.switch_client_at client name ~session:other.session);
  let steered = Option.get (observed client name) in
  assert (Client_observation.width steered = 100);
  assert (
    Session.Id.equal
      (Session.id (Option.get (Client_observation.session steered)))
      (Session.Target.id other.session));
  get (Client.request_detach_client_at client name);
  assert (observed client name = None)
```

```console
$ opam exec -- dune exec examples/showcase_clients.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-b61c05/server
steered: resized, refreshed, switched and detached
```

A request to detach confirms that tmux processed it, not that the peer exited.

## Send literal input and observe the reply with Eio

### [`Client.subscribe`][subscribe]: subscribe before sending input

The clients drive tmux through persistent control-mode connections, and
[`Client.subscribe`][subscribe] streams a pane's output over them.
[`Client.send_text`][send-text] types into the pane;
[`Client.wait_for_text`][wait-for-text] checks the screen.
The [Eio program](examples/showcase_watch.ml) starts its own server:

```console
$ opam exec -- dune exec examples/showcase_watch.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-f76d47/server
observed: changed
```

`send_text` types literally and never interprets shell syntax. Your application
owns `Eio_main`; the library starts no scheduler. A slow subscriber never blocks
another. More: [streaming and cancellation](docs/streaming.md).

## Packages and current limits

| Package | API or command guide | Use | Example |
| --- | --- | --- | --- |
| [libtmux](lib/) | [Libtmux][core-api] | Immutable graph and typed queries | [Describe a query](lib/README.md#build-and-inspect-a-query) |
| [libtmux-unix](unix/) | [Libtmux_unix][unix-api] | Blocking Linux client and scoped cancellation | [Capture a graph](unix/README.md#capture-once-traverse-after-closing) |
| [libtmux-eio](eio/) | [Libtmux_eio][eio-api] | Eio client, retained operations and subscriptions | [Send text and observe output](eio/README.md#subscribe-send-literal-text-await-output) |
| [libtmux-json](json/) | [Libtmux_json][json-api] | Bounded query and workspace JSON decoding | [Round-trip a query](json/README.md#round-trip-a-query-and-locate-invalid-input) |
| [libtmux-workspace](workspace/) | [Libtmux_workspace][workspace-api] | Configuration, plans and execution journals | [Preview a native workspace](workspace/README.md#preview-a-native-workspace) |
| [libtmux-workspace-cli](cli/) | [Workspace commands](docs/workspaces.md) | Validate, preview and apply JSON workspaces | [Check a configuration](cli/README.md#install-and-validate) |

### [`libtmux`](https://github.com/libtmux/libtmux-ocaml/tree/master/lib): the immutable graph and typed queries

[`Libtmux`][core-api] models captured sessions, window links and panes, and
evaluates queries over them with the standard library alone.

[API reference][core-api] · [Guides](https://libtmux.org/en/ocaml/latest/guides/) ·
[README](lib/README.md)

### [`libtmux-unix`](https://github.com/libtmux/libtmux-ocaml/tree/master/unix): the blocking Linux client

[`Libtmux_unix`][unix-api] connects to a daemon, captures the graph and runs
operations on the calling thread, with scoped cancellation.

[API reference][unix-api] · [README](unix/README.md)

### [`libtmux-eio`](https://github.com/libtmux/libtmux-ocaml/tree/master/eio): the Eio client

[`Libtmux_eio`][eio-api] adds retained operations and output subscriptions on
Eio.

[API reference][eio-api] · [README](eio/README.md)

### [`libtmux-json`](https://github.com/libtmux/libtmux-ocaml/tree/master/json): bounded JSON documents

[`Libtmux_json`][json-api] decodes and encodes query and workspace documents
within explicit bounds.

[API reference][json-api] · [README](json/README.md)

### [`libtmux-workspace`](https://github.com/libtmux/libtmux-ocaml/tree/master/workspace): configuration and plans

[`Libtmux_workspace`][workspace-api] validates a workspace, plans it against a
captured graph and journals its execution.

[API reference][workspace-api] ·
[Workspace docs](https://libtmux.org/en/ocaml/latest/workspace/) ·
[README](workspace/README.md)

### [`libtmux-workspace-cli`](https://github.com/libtmux/libtmux-ocaml/tree/master/cli): the `tmux-workspace` command

`tmux-workspace` validates, previews and applies JSON workspaces from the
shell.

[Workspace docs](https://libtmux.org/en/ocaml/latest/workspace/) ·
[Command guide](docs/workspaces.md) · [README](cli/README.md)

## What it leaves out

- **Live objects.** [`Session.t`][session], [`Window.t`][window] and
  [`Pane.t`][pane] are immutable values from one [`Snapshot.t`][snapshot].
  Capture again with [`Client.capture`][unix-capture], or subscribe with
  [`Client.subscribe`][subscribe], to observe changes.
- **A terminal emulator.** [`Client.capture_text`][unix-capture-text] reads
  visible rows rendered by tmux, and [`Client.subscribe`][subscribe] streams
  pane output bytes; neither runs an in-process terminal or TUI.
- **Implicit reconnection or `~/.tmux.conf` edits.** Clients bind targets to
  one connection generation, never reconnect on your behalf, and never edit
  user configuration files.
- **macOS, Windows and remote daemons.** The I/O packages require Linux
  pidfds, a shared PID namespace with the daemon, and local scratch storage.

## Support and status

- **Not on opam yet.** Install from source; remaining adoption gates are
  tracked in [status](docs/status.md) and
  [compatibility](docs/compatibility.md).
- **OCaml 5 and tmux 3.3a through 3.8 on Linux.** CI runs on OCaml 5.5.2
  against real tmux 3.3a and 3.8 servers without mocks.
- **Standard-library core.** `libtmux` and `libtmux-workspace` have no
  third-party runtime dependencies; Yojson, Eio and Cmdliner stay in their
  optional packages ([package boundaries](docs/packages.md)).

[Guides](docs/README.md) · [API docs](docs/api.md) ·
[Testing](docs/testing.md) · [Benchmarks](docs/benchmarking.md) ·
[Contributing](.github/CONTRIBUTING.md) · [Changelog](CHANGELOG.md) ·
[Logo assets](assets/README.md) ·
[AI policy](https://libtmux.org/en/meta/ai-policy/)

Licensed under [MIT](LICENSE). Part of the [libtmux.org](https://libtmux.org/)
family alongside Python [`libtmux`](https://github.com/tmux-python/libtmux),
sibling [language ports](https://github.com/libtmux), and
[`tmux`](https://github.com/tmux/tmux).

[core-api]: https://libtmux.org/en/ocaml/latest/reference/libtmux/
[unix-api]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix/
[eio-api]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio/
[json-api]: https://libtmux.org/en/ocaml/latest/reference/libtmux_json/
[workspace-api]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace/
[session]: https://libtmux.org/en/ocaml/latest/reference/libtmux-session/
[window]: https://libtmux.org/en/ocaml/latest/reference/libtmux-window/
[pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux-pane/
[snapshot]: https://libtmux.org/en/ocaml/latest/reference/libtmux-snapshot/
[query]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query/
[expr]: https://libtmux.org/en/ocaml/latest/reference/libtmux-expr/
[matching]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query-matching/
[window-index]: https://libtmux.org/en/ocaml/latest/reference/libtmux-window_link-index/
[unix-client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-t/
[unix-capture]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-capture/
[create-session]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-create_session/
[split-pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-split_pane/
[create-window]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-create_window/
[spawn]: https://libtmux.org/en/ocaml/latest/reference/libtmux-spawn-make/
[link-window]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-link_window/
[plan-panes]: https://libtmux.org/en/ocaml/latest/reference/libtmux-plan-panes/
[plan-explanation]: https://libtmux.org/en/ocaml/latest/reference/libtmux-plan-explanation/
[plan-source-filter]: https://libtmux.org/en/ocaml/latest/reference/libtmux-plan-source_filter/
[plan-residual]: https://libtmux.org/en/ocaml/latest/reference/libtmux-plan-residual/
[eio-client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-t/
[subscribe]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-subscribe/
[send-text]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-send_text/
[wait-for-text]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio-client-wait_for_text/
[unix-send-text]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-send_text/
[unix-send-keys]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-send_keys/
[unix-capture-text]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-capture_text/
[unix-resize-pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-resize_pane/
[unix-resize-window]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-resize_window/
[unix-kill-pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-kill_pane/
[unix-kill-window]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-kill_window/
[unix-kill-session]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-kill_session/
[unix-read-option]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-read_option/
[unix-set-hook]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-set_hook/
[unix-set-environment]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-set_environment/
[unix-remove-environment]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-remove_environment/
[unix-rotate-panes]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-rotate_panes/
[unix-zoom-pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-zoom_pane/
[unix-move-pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-move_pane/
[unix-break-pane]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-break_pane/
[unix-resize-control-client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-resize_control_client_at/
[unix-refresh-client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-refresh_client_at/
[unix-set-option]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-set_option/
[unix-swap-panes]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-swap_panes/
[unix-switch-client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-switch_client_at/
[unix-detach-client]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-request_detach_client_at/
[unix-private-daemon]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix/#val-with_private_daemon
[eio-private-daemon]: https://libtmux.org/en/ocaml/latest/reference/libtmux_eio/#val-with_private_daemon
[unix-kill-server]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-client-kill_server/
[unix-bootstrap]: https://libtmux.org/en/ocaml/latest/reference/libtmux_unix-workspace-submit_bootstrap/
