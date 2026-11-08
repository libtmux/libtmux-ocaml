# Browse the OCaml API

The public `.mli` files define the API. They document module roles, input and
result types, local versus effectful operations, ownership, ordering, limits
and failure behavior. Source examples are compiled against installed libraries.

| Package | Public interface | Start with |
| --- | --- | --- |
| [Core](../lib/) | [Libtmux](../lib/libtmux.mli) | `Snapshot`, `Pane`, `Expr`, `Query`, `Operations` |
| [Blocking](../unix/) | [Libtmux_unix](../unix/libtmux_unix.mli) | `Client`, `Operation`, `Subscription`, `Cancellation`, `Workspace` |
| [Concurrent](../eio/) | [Libtmux_eio](../eio/libtmux_eio.mli) | `Client`, `Operation`, `Subscription`, `Workspace` |
| [JSON](../json/) | [Libtmux_json](../json/libtmux_json.mli) | `Expr`, `Workspace`, `Error`, `Decode_error` |
| Workspaces | [Libtmux_workspace](../workspace/libtmux_workspace.mli) | `Config`, `Plan`, `Execution` |

The `libtmux-workspace-cli` package installs the `tmux-workspace` executable.
Its [workspace guide](workspaces.md) covers configuration, exits and recovery;
it does not expose an additional OCaml library.

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

## Export public interfaces for the shared site

The development exporter reads the five public `.cmti` interfaces listed in
[`api_modules.json`](../tools/api_modules.json), verifies their Dune installation
entries and embedded signatures, and checks that source bytes match the library
commit. It preserves native declarations, doc comments, labels and opaque types.
It rejects stale annotations and `.cmi`-only input. Internal compilation units
stay outside the reference.

With the development dependencies installed, build the optional tool:

```console
$ LIBTMUX_API_EXPORT=1 opam exec -- dune build @install tools/api_export.exe
```

Export the checked-out public interfaces:

```console
$ opam exec -- python3 tools/export_api.py \
    --output _build/docs/ocaml.json
```

The artifact records the library commit, exporter commit and input hashes
separately. Uncommitted exporter changes have hashes and a null exporter
revision. Optional arguments have no invented default. When a type and value
share a spelling, the type's reference ID ends in `:type`; its native qualified
name remains unchanged. Compiler libraries, odoc-parser and JSON tooling belong
to this opt-in development tool, not the core runtime.

The manifest classifies nested workspace APIs separately from their transport
or codec package. These declarations retain their actual public module and
package names while appearing in the shared site's workspace reference.

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
