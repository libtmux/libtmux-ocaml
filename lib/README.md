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

**libtmux · immutable model and typed queries**

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ocaml/)

</div>

Build [queries][query] and inspect [captured tmux graphs][snapshot] with
[`Libtmux`][api]. The core uses the OCaml standard library and performs no tmux
I/O. Add a [blocking client](../unix/) or [Eio client](../eio/) when acquiring
observations or changing the server.

[API](https://libtmux.org/en/ocaml/latest/reference/libtmux/) ·
[Examples](#build-and-inspect-a-query) ·
[Object graph](../docs/graph.md) ·
[Queries](../docs/queries.md) · [Package boundaries](../docs/packages.md)

## Install and link

Use the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2**. There is no opam release yet. That route installs this
workspace's packages and activates the local switch; run the commands below
from the checkout root.

In a separate application, create `dune-project` containing `(lang dune 3.24)`.
Copy the example as `query_description.ml` and use this `dune` file:

```dune
(executable
 (name query_description)
 (libraries libtmux))
```

## Build and inspect a query

### [`Expr`][expr]: typed fields and operators

This complete program needs no tmux server. [`Expr`][expr] combines typed
fields and operators into inspectable data. [`Query.exactly_one`][exactly-one]
counts duplicate entries rather than silently deduplicating them.

<!-- example: examples/query_description.ml -->

```ocaml
open Libtmux

let editors : Pane.t Expr.t =
  Expr.all
    [
      Expr.Bool.is_true Pane.Fields.active;
      Expr.Text.is_in Pane.Fields.current_command [ "nvim"; "vim" ];
      Expr.Int.ge Pane.Fields.width 120;
    ]

let () =
  print_endline (Expr.describe editors);
  match Query.exactly_one (List.to_seq [ "%1"; "%1" ]) with
  | Error (Cardinality.Multiple_matches { at_least }) ->
      Printf.printf "ambiguous: at least %d entries\n" at_least
  | _ -> failwith "duplicate entries must count separately"
```

```console
$ opam exec -- dune exec examples/query_description.exe
```

```text
all [pane_active = true; pane_current_command in ["nvim"; "vim"]; pane_width >= 120]
ambiguous: at least 2 entries
```

## Process a captured graph

### [`Snapshot.t`][snapshot]: read captured values without tmux I/O

A [`Snapshot.t`][snapshot] comes from a client capture or validated
[`Snapshot.create`][snapshot-create] input.
Use native predicates over its immutable arrays. This function is part of the
[complete, executed query program](../examples/native_query.ml):

<!-- example: examples/native_query.ml#native-filter -->

```ocaml
let active_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
  |> Seq.map Pane.id |> List.of_seq
```

### [`Query.matching`][matching]: apply a typed predicate

For inspectable filters, use [`Query.matching`][matching]. This selects active
terminal panes at least 80 columns wide:

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

Combine relationships with typed quantifiers to select sessions containing
at least one matching pane:

<!-- example: examples/native_query.ml#relationship-filter -->

```ocaml
let sessions_with_room snapshot =
  let expression =
    Expr.Rel.any Session.Relations.windows
      (Expr.Rel.any Window.Relations.panes roomy_terminals)
  in
  Snapshot.sessions snapshot |> Iarray.to_seq |> Query.matching expression
  |> Seq.map Session.name |> List.of_seq
```

The graph is `Session → Window_link → Window → Pane`. A shared window can have
several session links; each link owns its index and current state. Collections
are `Iarray.t`, and sequences derived from a snapshot read captured values.

Keep these contracts in mind:

- Queries preserve input order and duplicates. Establish `Query.exactly_one`
  before a mutation when ambiguity matters.
- Observations survive client closure. Holding one observation retains its
  complete snapshot; copy scalar summaries when retaining only a few fields.
- Targets retain their source generation. An ID or a JSON document does not
  authorize a mutation on a new connection.
- `Plan.panes` describes source-filtering possibilities. Capture clients do
  not execute those plans.

[Run the full graph example](../README.md#read-a-real-tmux-graph) ·
[Query JSON](../json/) · [Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[api]: https://libtmux.org/en/ocaml/latest/reference/libtmux/
[snapshot]: https://libtmux.org/en/ocaml/latest/reference/libtmux-snapshot-t/
[snapshot-create]: https://libtmux.org/en/ocaml/latest/reference/libtmux-snapshot-create/
[query]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query/
[expr]: https://libtmux.org/en/ocaml/latest/reference/libtmux-expr/
[matching]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query-matching/
[exactly-one]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query-exactly_one/
