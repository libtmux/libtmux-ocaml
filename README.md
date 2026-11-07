# libtmux-ocaml

Native OCaml values and queries for tmux, targeting OCaml 5.5.2.

The development tree provides immutable snapshots, typed queries, and native
Linux clients for Eio and blocking scripts. Transport qualification is in
progress; workspace tools and MCP remain implementation stages. No package
release exists yet.

Start with the [native capture example](examples/native_capture.ml): it connects
to an explicit socket, captures the graph, closes the client and prints active
pane IDs from the retained snapshot. See the current
[compatibility evidence](docs/compatibility.md).

Filter captured panes with ordinary functions:

```ocaml
open Libtmux

let active_ids snapshot =
  Snapshot.panes snapshot
  |> Iarray.to_seq
  |> Seq.filter Pane.active
  |> Seq.map Pane.id
  |> List.of_seq
```

Use typed expressions when the query needs inspection or reuse:

```ocaml
let editors =
  Expr.all [
    Expr.Bool.is_true Pane.Fields.active;
    Expr.Text.is_in Pane.Fields.current_command ["nvim"; "vim"];
    Expr.Int.ge Pane.Fields.width 120;
  ]

let editor_ids snapshot =
  Snapshot.panes snapshot
  |> Iarray.to_seq
  |> Query.matching editors
  |> Seq.map Pane.id
  |> List.of_seq
```

Both examples operate on captured data. Collections use `Iarray`, `Seq` and
`List`; observations and relationship traversal perform no I/O. Windows linked
more than once retain separate `Window_link` observations. See the
[field reference](docs/fields.md) and contracts in [libtmux.mli](lib/libtmux.mli).

The native package name is `libtmux`. Its runtime uses the standard library.
[libtmux.opam](libtmux.opam) owns package metadata and pins OCaml and Dune;
[.tool-versions](.tool-versions) pins opam.

Target only the latest stable OCaml release in 2026. Older compiler versions
are out of scope. As stable releases advance, replace the exact compiler pin
and validate the new target.

See [CONTRIBUTING.md](.github/CONTRIBUTING.md) for setup and metadata checks,
[WRITING.md](.github/WRITING.md) for prose and commit conventions, and
[AGENTS.md](AGENTS.md) for agent instructions.

Licensed under the [MIT License](LICENSE).
