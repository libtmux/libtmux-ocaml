# Browse the OCaml API

The public `.mli` files define the API. They document module roles, input and
result types, local versus effectful operations, ownership, ordering, limits
and failure behavior. Source examples are compiled against installed libraries.

| Package | Public interface | Start with |
| --- | --- | --- |
| Core | [Libtmux](../lib/libtmux.mli) | `Snapshot`, `Pane`, `Expr`, `Query`, `Operations` |
| Blocking | [Libtmux_unix](../unix/libtmux_unix.mli) | `Client`, `Operation`, `Subscription`, `Cancellation`, `Workspace` |
| Concurrent | [Libtmux_eio](../eio/libtmux_eio.mli) | `Client`, `Operation`, `Subscription`, `Workspace` |
| JSON | [Libtmux_json](../json/libtmux_json.mli) | `Expr`, `Workspace`, `Decode_error` |
| Workspaces | [Libtmux_workspace](../workspace/libtmux_workspace.mli) | `Config`, `Plan`, `Execution` |

Install the development documentation dependency outside validation loops:

```console
$ opam install odoc.3.2.2
```

Build the native reference:

```console
$ opam exec -- dune build @doc
```

Open `_build/default/_doc/_html/index.html` in a browser. Package entry pages
link to the public modules; module pages expose nested abstract types, labeled
arguments, result values and cross-references. The `.mli` source links above
remain usable directly from the repository.

There is no published OCaml API site yet. Shared-site export and publication
are separate acceptance gates; a successful local odoc build does not prove a
remote deployment. See [current status](status.md).

## Read the effect boundary

`Snapshot.panes`, `Window.panes`, field access and `Expr.compile` read captured
values. `Client.capture`, `Client.run`, subscription admission and event waits
perform explicit I/O. `Operation.inspect` and subscription polling are local.
A cursor from streamed bytes does not identify a snapshot acquisition time.

The compiler rejects mixing entity kinds or using a text operator on an integer
field. External JSON crosses a validation boundary before it becomes a typed
expression or configuration. Abstract IDs do not independently prove daemon
identity; operational targets retain their connection source.

[First use](getting-started.md) · [Graph](graph.md) · [Queries](queries.md) ·
[Streaming](streaming.md) · [Testing](testing.md)
