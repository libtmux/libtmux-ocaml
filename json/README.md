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

**libtmux-json · bounded JSON interchange**

</div>

Decode query documents into typed [`Libtmux.Expr.t`][expr] values and validate
workspace configuration with [`Libtmux_json`][api]. The codec performs no tmux
or filesystem I/O.
It depends on the [core](../lib/), the pure [workspace package](../workspace/),
and Yojson.

[API](https://libtmux.org/en/ocaml/latest/reference/libtmux_json/) ·
[Examples](#round-trip-a-query-and-locate-invalid-input) ·
[Query semantics](../docs/queries.md) ·
[Workspaces](../docs/workspaces.md) · [Package boundaries](../docs/packages.md)

## Install and link

Use the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2**. There is no opam release yet. That route installs this
workspace's packages and activates the local switch; run the commands below
from the checkout root.

In a separate application, create `dune-project` containing `(lang dune 3.24)`.
Copy the example as `query_json.ml` and use this `dune` file:

```dune
(executable
 (name query_json)
 (libraries libtmux libtmux-json))
```

## Round-trip a query and locate invalid input

### [`Expr.of_string`][decode]: validate a query document

[`Expr.to_string`][encode] serializes a typed query;
[`Expr.of_string`][decode] validates it against the same model witness.
Invalid external data returns a [`Decode_error.t`][decode-error] with a JSON
pointer, category and message.

<!-- example: examples/query_json.ml -->

```ocaml
open Libtmux

let get = function
  | Ok value -> value
  | Error error ->
      failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error)

let () =
  let query = Expr.Text.starts_with Pane.Fields.current_command "nv" in
  let document = get (Libtmux_json.Expr.to_string Model.pane query) in
  print_endline document;
  let decoded = get (Libtmux_json.Expr.of_string Model.pane document) in
  assert (Expr.describe decoded = Expr.describe query);
  let invalid =
    {|{"schema":"libtmux.filter/1","model":"pane","expr":{"node":"compare","field":"pane_width","op":"ge","value":"wide"}}|}
  in
  match Libtmux_json.Expr.of_string Model.pane invalid with
  | Error error -> Printf.printf "invalid operand at %s\n" error.pointer
  | Ok _ -> failwith "string width was accepted"
```

```console
$ opam exec -- dune exec examples/query_json.exe
```

The first line is the portable document:

```json
{"schema":"libtmux.filter/1","model":"pane","expr":{"node":"compare","field":"pane_current_command","op":"starts_with","value":"nv"}}
```

The second line is `invalid operand at /expr/value`. Apply the decoded expression
to captured panes through [`Query.matching`][matching] or
[`Expr.compile`][compile]; decoding itself neither acquires observations nor
executes commands.

## Supported documents and limits

| API | Schema | Contract |
| --- | --- | --- |
| `Expr.of_string`, `Expr.decode` | `libtmux.filter/1` | Shared scalar pane fields and Boolean composition |
| `Workspace.of_string`, `Workspace.decode` | `libtmux.workspace/1` | Validated configuration with an explicit document directory |
| `Workspace.encode_plan` | `libtmux.workspace-plan/1` | Advisory preview without executable authority |
| `Workspace.encode_receipt` | `libtmux.workspace-receipt/1` | Retained outcomes and cleanup evidence |

Use the string decoders for untrusted documents: they enforce a 64 KiB input
bound, UTF-8 and at most 32 JSON nesting levels before parsing. Query expressions
have at most 1,024 nodes and membership lists at most 256 values. Query numeric
operands must fit signed 32-bit integers; workspace numeric options use signed
64-bit integers. Unknown and duplicate properties are rejected.

Query interchange deliberately rejects Java regex, relationships and native
extension fields with `Unsupported`. Native OCaml expressions support more than
the wire subset; [the query guide](../docs/queries.md) describes that boundary.

For workspaces, pass the absolute document directory as `~directory`; validation
resolves relative paths without reading them. JSON receipts and IDs convey
neither live targets nor permission to replay an uncertain mutation. Exported
plans and receipts have a 4 MiB bound. See the [workspace guide](../docs/workspaces.md)
for complete configuration, planning and execution examples.

[Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[api]: https://libtmux.org/en/ocaml/latest/reference/libtmux_json/
[expr]: https://libtmux.org/en/ocaml/latest/reference/libtmux-expr-t/
[encode]: https://libtmux.org/en/ocaml/latest/reference/libtmux_json-expr-to_string/
[decode]: https://libtmux.org/en/ocaml/latest/reference/libtmux_json-expr-of_string/
[decode-error]: https://libtmux.org/en/ocaml/latest/reference/libtmux_json-decode_error-t/
[matching]: https://libtmux.org/en/ocaml/latest/reference/libtmux-query-matching/
[compile]: https://libtmux.org/en/ocaml/latest/reference/libtmux-expr-compile/
