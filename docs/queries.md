# Query captured data

Capture once, then use standard collections. The [complete program](../examples/native_query.ml)
closes its blocking client before evaluating any of the functions below.
Follow the [README setup](../README.md#read-a-real-tmux-graph) first.

## Use a native predicate

<!-- example: examples/native_query.ml#native-filter -->

```ocaml
let active_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
  |> Seq.map Pane.id |> List.of_seq
```

`Snapshot.panes` returns an immutable array of captured panes. Converting it to
a sequence does not acquire anything. Repeated traversal sees captured values;
stateful callbacks supplied by an application can still behave differently.

## Describe a typed query

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

`Expr.compile` returns an ordinary predicate. `Query.matching` compiles once
when constructed and preserves order and multiplicity. Field descriptors carry
both entity and value types, so invalid entity/operator combinations fail in
the compiler. Boolean `Expr.all []` is true and `Expr.any []` is false.

## Follow relationships without fetching

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

Relationships traverse the complete captured graph. `Expr.Rel.any` over no
children is false; `all` and `none` over no children are true. Put conditions
inside one `any` when the same child must satisfy both. Two independent
existentials can match different children.

## Establish cardinality before acting

`Query.exactly_one` returns `No_match` or `Multiple_matches {at_least=2}` instead
of choosing the first element. It stops once it finds a second match; proving
uniqueness exhausts the remaining finite sequence. `one_or_none` returns an
option while retaining an ambiguity error. Duplicate entries count separately.

Select first, inspect the result, then submit a mutation. Selection does not
lock tmux; a target can disappear between observation and action. The
[control guide](control.md) explains that failure boundary.

## Decode portable query data explicitly

`Libtmux_json.Expr.of_string Model.pane` validates the shared scalar pane
subset of `libtmux.filter/1`. It rejects duplicate/unknown keys, wrong operand
types, invalid UTF-8, oversized/deep documents and Java regex. Native closures
stay in `Seq.filter`; they have no portable wire identity.

`Libtmux.Plan.make` describes source-side acquisition separately from local
matching. Inspect `source_filter` and residual evaluation, and use
`Require_exact` when falling back locally would be unacceptable. Conjunctions,
disjunctions, negation and relationships require different lowering rules;
local sequence processing never issues a tmux query implicitly.

[Field reference](fields.md) · [API](api.md) · [Guide](README.md)
