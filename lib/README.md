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
[`Libtmux`][api]. It does no tmux I/O and needs only the standard library. To
reach a server, add the [blocking client](../unix/) or [Eio client](../eio/).

[API](https://libtmux.org/en/ocaml/latest/reference/libtmux/) ·
[Examples](#build-and-inspect-a-query) ·
[Object graph](../docs/graph.md) ·
[Queries](../docs/queries.md) · [Package boundaries](../docs/packages.md)

## Install and link

Not on opam yet: follow the [source install](../README.md#install-from-source)
and run the commands below from the checkout root.

In your own project, set `(lang dune 3.24)` in `dune-project`, copy the example
as `query_description.ml` and use this `dune` file:

```dune
(executable
 (name query_description)
 (libraries libtmux))
```

## Build and inspect a query

### [`Expr`][expr]: typed fields and operators

No tmux server needed. [`Expr`][expr] builds typed filters as inspectable data;
[`Query.exactly_one`][exactly-one] counts duplicates instead of hiding them.

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

More: [query guide](../docs/queries.md).

## Process a captured graph

### [`Snapshot.t`][snapshot]: read captured values without tmux I/O

A [`Snapshot.t`][snapshot] comes from a client capture or
[`Snapshot.create`][snapshot-create]. Plain predicates work over its immutable
arrays. From the [query program](../examples/native_query.ml):

<!-- example: examples/native_query.ml#native-filter -->

```ocaml
open Libtmux

let active_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
  |> Seq.map Pane.id |> List.of_seq
```

### [`Query.matching`][matching]: apply a typed predicate

[`Query.matching`][matching] applies an inspectable filter. This one selects
active terminal panes at least 80 columns wide:

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

### [`Expr.Rel.any`][rel-any]: sessions with a matching pane

Quantify over relationships, here sessions with at least one matching pane:

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
several links; each link owns its index and state. Collections are `Iarray.t`.

Notes:

- Queries keep input order and duplicates. Use `Query.exactly_one` before a
  mutation when ambiguity matters.
- An observation outlives its client but retains the whole snapshot; copy the
  few fields you need.
- A target belongs to the connection that produced it. An ID or JSON document
  cannot mutate on a new connection.
- `Plan.panes` describes source filtering; capture clients do not run it.

[Run the full graph example](../README.md#read-a-real-tmux-graph) ·
[Query JSON](../json/) · [Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[api]: https://libtmux.org/en/ocaml/latest/reference/libtmux/
[snapshot]: https://libtmux.org/en/ocaml/latest/reference/libtmux-snapshot-t/
[snapshot-create]: https://libtmux.org/en/ocaml/latest/reference/libtmux-snapshot-create/
[query]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query/
[expr]: https://libtmux.org/en/ocaml/latest/reference/libtmux-expr/
[matching]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query-matching/
[exactly-one]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query-exactly_one/
[rel-any]: https://libtmux.org/en/ocaml/latest/reference/libtmux-expr-rel-any/
