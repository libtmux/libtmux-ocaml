# Create a workspace from JSON

`tmux-workspace` validates a JSON configuration, previews an advisory plan, and
applies a fresh plan to the selected tmux server. Install it through the
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

`check` needs no server. Run it from the repository root:

```console
$ opam exec -- tmux-workspace check examples/workspace/project.json
```

Expected output: `Valid workspace "ocaml-project": 2 windows, 3 panes`.

`plan` and `apply` act on `--socket PATH` (`-S`) or `--socket-name NAME` (`-L`),
or when neither flag is given, on `LIBTMUX_SOCKET_PATH`, else `LIBTMUX_SOCKET`,
else the socket in `TMUX`, else tmux's `default` socket, requiring tmux 3.3a or
newer. `plan` prints the advisory actions without changing anything. `apply`
rereads the document and runs a fresh plan; `--json` writes a
[`libtmux.workspace-receipt/1`](../json/libtmux_json.mli) document whose
`status` is `succeeded` when `failed`, `uncertain` and `skipped` are empty, and
each creation records the IDs tmux returned. Without `--require-existing`,
`apply` can start a missing endpoint by creating the requested session; that
server uses the normal tmux configuration and keeps running after the CLI's
client closes, so its appearance does not grant daemon ownership. `plan` on a
missing endpoint checks the local tmux version and returns a bootstrap plan
without creating the socket.

The [complete program](../examples/workspace_apply.ml) runs the same document
through the library with no server of your own. It decodes the file with
`Libtmux_json.Workspace`, starts a private server, bootstraps the plan, checks
the receipt, reads the resulting windows and stops the server:

```console
$ opam exec -- dune exec examples/workspace_apply.exe -- tmux
```

Expected output:

```text
Valid workspace "ocaml-project": 2 windows, 3 panes
Plan: 6 actions
Receipt: succeeded
editor:2
logs:1
```

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

The [retained-operation example](recovery.md) demonstrates waiter recovery.
The [native workspace example](workspace-recovery.md) interrupts an apply,
inspects its journal after client cleanup and verifies compensation. Read the
available journal, identify proven effects, then choose another explicit action.
A saved JSON receipt describes observations; it is not an executable target or
a transaction to replay.

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
The [native bootstrap walkthrough](bootstrap.md) starts one private session
without a JSON dependency and captures its graph through the resulting client.
See the [API reference](api.md), [control outcomes](control.md) and
[compatibility](compatibility.md).
