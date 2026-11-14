<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="docs/assets/logo.svg" type="image/svg+xml">
    <img src="docs/assets/logo-512.png" width="128" height="128" alt="libtmux for OCaml">
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

More: [installation guide](docs/getting-started.md), for use from another Dune project.

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
socket=/tmp/libtmux-ocaml-showcase-0cd3a1/server
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
socket=/tmp/libtmux-ocaml-showcase-0cd3a1/server
layout: 3 horizontal panes
```

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
socket=/tmp/libtmux-ocaml-showcase-f76d47/server
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

- **Dependencies.** Core and the workspace library use the standard library
  alone; JSON and Eio are optional. [Package boundaries](docs/packages.md).
- **Not supported.** macOS, Windows and remote daemons.
- **Status.** [Adoption gaps](docs/status.md) ·
  [Compatibility](docs/compatibility.md).
- **More.** [API docs](docs/api.md) · [Testing](docs/testing.md) ·
  [Benchmarks](docs/benchmarking.md) · [Workspace guide](docs/workspaces.md).

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

For development, read [CONTRIBUTING.md](.github/CONTRIBUTING.md).
Licensed under [MIT](LICENSE).

[Branding assets](docs/branding.md) include the logo, icons, and social cards.

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
