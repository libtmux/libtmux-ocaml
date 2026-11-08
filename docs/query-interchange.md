# Share a scalar pane query

`Libtmux_json.Expr` reads and writes the following subset of
[`libtmux.filter/1`][java-wire]. Use `Model.pane` as the model witness. This
document defines the OCaml interoperability boundary; the
[query guide](queries.md) shows local evaluation and the
[complete JSON program](../examples/query_json.ml) demonstrates decoding,
encoding and structured errors.

## Document and nodes

A document has exactly `schema`, `model` and `expr` properties. The supported
values are `"libtmux.filter/1"` and `"pane"`. An expression is one of these nodes:

| `node` | Other required properties | Meaning |
| --- | --- | --- |
| `compare` | `field`, `op`, `value` | Compare one canonical scalar field |
| `and` | `operands`: expression array | Every operand matches; empty is true |
| `or` | `operands`: expression array | Any operand matches; empty is false |
| `not` | `operand`: expression | Negate one expression |

Property order is irrelevant. Duplicate, missing and unknown properties are
errors. Encoders preserve query meaning, not the original spelling: a
`not_equals` comparison can encode as `not` around `equals`.

## Fields and operators

Field names are case-sensitive canonical identities, not arbitrary accessors.

| Value type | Fields | Operators |
| --- | --- | --- |
| String | `pane_id`, `pane_current_command`, `pane_title`, `pane_current_path` | `equals`, `not_equals`, `starts_with`, `ends_with`, `contains`, `in` |
| Integer | `pane_index`, `pane_width`, `pane_height`, `pane_left`, `pane_top` | `equals`, `not_equals`, `less_than`, `at_most`, `greater_than`, `at_least` |
| Boolean | `pane_active` | `equals`, `not_equals` |

`value` has the field's JSON type. String `in` takes an array of strings and
matches equality with any member; an empty array matches nothing. Integers must
be integral JSON numbers in the signed 32-bit range, from −2,147,483,648 through
2,147,483,647. Floating-point values are rejected.

Text is valid UTF-8 with exact, case-sensitive matching. The codec performs no
normalization or case folding. Native OCaml predicates can process arbitrary
bytes, but invalid UTF-8 has no representation in this query schema.

Relationships, other models, native extension fields such as `pane_dead`,
optional fields such as `pane_pid`, integer membership and Java's `matches`
regex operator are outside this subset. Use native expressions or ordinary
`Seq.filter` for local behavior outside it.

## Bounds and errors

Both decoding and encoding enforce these limits:

| Resource | Limit |
| --- | --- |
| JSON document | 65,536 bytes |
| JSON nesting | 32 levels |
| Expression nodes | 1,024 |
| String membership values | 256 |

`of_string` checks input bytes and nesting before parsing. `decode` validates
the supplied Yojson tree, including duplicate properties and the size of its
compact JSON representation. Encoding applies the same subset and bounds.

Failures return `Decode_error.t`: a JSON pointer, category and message. For
example, a string supplied to `pane_width` reports `Wrong_type` at
`/expr/value`. The decoder returns the first detected error, not an aggregate
validation report. It does not include the whole input in the error.

## Reproduce the compatibility check

The [conformance procedure](../test/conformance/README.md) pins the Java source,
verifies prepared artifacts, rebuilds the OCaml peer and exchanges queries in
both directions over the same fixture. The current 66 cases establish the
tested scalar behavior. They do not imply support for the rest of Java's query
language or a Java runtime dependency for OCaml users.

[java-wire]: https://github.com/libtmux/libtmux-java/blob/e8a39689d8d60968ac978a1dd2a89c6112333896/docs/guide/filtering.md
