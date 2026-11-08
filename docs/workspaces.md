# Create a workspace from JSON

`tmux-workspace` validates a JSON configuration, previews an advisory plan, and
applies a fresh plan to an explicit socket. Install it through the
[source installation](../README.md#install-from-source); `opam install .`
includes the CLI. Run this guide from the repository root.

`check` performs no tmux I/O. `plan` observes the endpoint and never starts a
daemon. `apply` rereads the document, checks current state, then executes ordered
actions. A preview is not a transaction or an executable target.

## Define the layout

The shipped [project.json](../examples/workspace/project.json) creates an
`editor` window with two panes and a `logs` window with one. Each pane runs
`/bin/cat -u` directly, keeping the demonstration alive without a shell command.

<!-- example: examples/workspace/project.json -->

```json
{
  "schema": "libtmux.workspace/1",
  "session": "ocaml-project",
  "cwd": ".",
  "width": 120,
  "height": 40,
  "environment": {"PROJECT": "ocaml"},
  "options": [{"name": "@project", "kind": "text", "value": "ocaml"}],
  "windows": [
    {
      "name": "editor",
      "layout": "even-horizontal",
      "panes": [
        {"exec": ["/bin/cat", "-u"]},
        {"exec": ["/bin/cat", "-u"], "direction": "right"}
      ]
    },
    {"name": "logs", "panes": [{"exec": ["/bin/cat", "-u"]}]}
  ]
}
```

Relative directories resolve against the JSON file's directory. Environment
values merge from session to window to pane. `exec` supplies literal argv;
`shell` explicitly requests shell interpretation. They are mutually exclusive.
Omitting both uses tmux's default command. `startup` entries send literal text
followed by Enter; they do not wait for a command to finish.

## Validate, preview and apply

This walkthrough uses a private server and an empty tmux configuration. The
`seed` session keeps the server alive while the CLI creates the project.
Inherited `TMUX` and `TMUX_PANE` do not select the endpoint.

<!-- workspace-walkthrough:begin -->

```console
$ export LIBTMUX_WORKSPACE_DIR="$(mktemp -d -t libtmux-ocaml-workspace.XXXXXX)"
```

Copying the file also makes its working directory the private directory:

```console
$ cp examples/workspace/project.json "$LIBTMUX_WORKSPACE_DIR/project.json"
```

```console
$ opam exec -- tmux-workspace check "$LIBTMUX_WORKSPACE_DIR/project.json"
```

Expected output: `Valid workspace "ocaml-project": 2 windows, 3 panes`.

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_WORKSPACE_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s seed \
    -- "exec cat"
```

```console
$ opam exec -- tmux-workspace plan \
    --socket "$LIBTMUX_WORKSPACE_DIR/server" \
    --require-existing \
    "$LIBTMUX_WORKSPACE_DIR/project.json"
```

The plan lists session creation, settings, the split and layout, and the logs
window. Applying it requires the original configuration:

```console
$ opam exec -- tmux-workspace apply \
    --socket "$LIBTMUX_WORKSPACE_DIR/server" \
    --require-existing \
    --json \
    "$LIBTMUX_WORKSPACE_DIR/project.json" \
    > "$LIBTMUX_WORKSPACE_DIR/receipt.json"
```

The receipt uses [`libtmux.workspace-receipt/1`](../json/libtmux_json.mli).
On success, `status` is
`succeeded`; `failed`, `uncertain` and `skipped` are empty. Each creation records
the IDs returned by tmux. Check the resulting windows independently:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_WORKSPACE_DIR/server" \
    list-windows \
    -t '=ocaml-project' \
    -F '#{window_name}:#{window_panes}'
```

Expected output is `editor:2` followed by `logs:1`.

Remove only the sessions this walkthrough created:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_WORKSPACE_DIR/server" \
    kill-session \
    -t '=ocaml-project'
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_WORKSPACE_DIR/server" \
    kill-session \
    -t '=seed'
```

```console
$ rm -f -- "$LIBTMUX_WORKSPACE_DIR/server" \
    "$LIBTMUX_WORKSPACE_DIR/project.json" \
    "$LIBTMUX_WORKSPACE_DIR/receipt.json"
```

```console
$ rmdir "$LIBTMUX_WORKSPACE_DIR"
```

<!-- workspace-walkthrough:end -->

Without `--require-existing`, `apply` can start a missing endpoint by creating
the requested session. That server uses the normal tmux configuration. Closing
the CLI's client leaves the server running; its appearance does not grant
daemon ownership. `plan` on a missing endpoint checks the local tmux version
and returns a bootstrap plan without creating the socket.

## Collisions and recovery

An existing session name fails with exit 4 by default. `--append` adds new
windows to that session and rejects window-name collisions. Append never
changes the existing session's options or environment; omit those session
settings from an append document. It preserves existing panes.

Use `--json` on `check` or `plan` to obtain `document_digest`, then pass that
value through `--expect-document` on apply. A changed document fails before
endpoint I/O. The digest does not lock tmux state. Each apply builds and
rechecks its own plan on the current connection generation.

On failure or SIGINT, inspect the receipt before deciding what to do next.
Default compensation kills only panes whose creation the journal proved, in
reverse order. A foreign pane moved into a new window remains. `--keep-partial`
retains proven creations instead. Cleanup failures and creations whose IDs
could not be bound remain explicit. Never rerun an uncertain mutation solely
because its caller was interrupted.

The [native recovery example](recovery.md) demonstrates the cancellation,
inspection and fresh-postcondition sequence for a retained operation. Workspace
callers use the same discipline with `Workspace.inspect`: read the available
journal, identify proven effects, then choose compensation or another explicit
action. A saved JSON receipt describes observations; it is not an executable
target or a transaction to replay.

The execution journal is retained in process memory. `await` initiates steps
only once for a particular execution handle; a new handle or CLI invocation
starts a new execution. Operation IDs correlate receipts and do not suppress
duplicates. Neither a retained handle nor an exported receipt is a durable
write-ahead log. Compensation cannot undo files, network requests or other
effects of the programs launched in panes.

| Exit | Meaning |
| --- | --- |
| 0 | Validation, planning or apply succeeded |
| 2 | Invalid arguments or document |
| 3 | Required endpoint missing |
| 4 | Collision, changed document or stale plan |
| 5 | Failed, partial or uncertain apply; inspect the receipt |
| 6 | Transport, capability or result-delivery failure |
| 130 | SIGINT; the available journal is emitted within the cleanup bound |

SIGINT does not undo admitted commands. Receipt output is bounded; a blocked or
broken stdout cannot produce a successful exit. Forced process termination
cannot promise a delivered receipt. Expected failures are distinct from Eio
cancellation in the native API, which propagates cancellation to the caller.

## Bounds and native callers

Documents use UTF-8 JSON with a 64 KiB input bound and depth limit 32. Unknown
and duplicate properties fail. Configurations allow at most 64 windows and 256
panes; a plan allows at most 4096 actions. Plans and receipts have a 4 MiB output
bound. Plans omit environment values, option values and startup text. They can
still contain command arguments and paths; treat them as application data.

For native code, use `Libtmux_json.Workspace.of_string`,
`Libtmux_workspace.Plan.make`, and the backend's `Workspace.submit` or
`Workspace.submit_bootstrap`. `inspect` reads the retained journal locally;
`await` performs I/O. The application owns the Eio switch and scheduler.
See the [API reference](api.md), [control outcomes](control.md) and
[compatibility evidence](compatibility.md).
