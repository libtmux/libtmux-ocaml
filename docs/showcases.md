# Run a complete capability example

Each program creates a private tmux workspace, performs one task, verifies the
result and closes its clients. Copy the whole file into a Dune project or run
it from this checkout after [installation](getting-started.md).

The programs use a minimal tmux configuration that makes their private daemon
exit when its last client detaches. They accept an optional tmux binary,
not a borrowed server socket. Their setup uses the public workspace API; the
task uses the client API. The Eio example starts its scheduler after setup and
subscribes before sending the bytes it observes.

For a separate project, save a program as `main.ml` and use these Dune libraries:

```dune
(executable
 (name main)
 (libraries libtmux libtmux-workspace libtmux-unix unix))
```

The watch program also needs `libtmux-eio` and `eio_main`. The
[installation guide](getting-started.md) supplies the project and switch setup.

| Task | Complete program | Expected outcome line |
| --- | --- | --- |
| Navigate sessions, shared windows and panes | [Graph](../examples/showcase_graph.ml) | `graph: 2 sessions, 2 windows, 3 links, 2 panes` |
| Observe future bytes concurrently | [Watch](../examples/showcase_watch.ml) | `observed: changed` |
| Send literal input and Enter | [Keys](../examples/showcase_send_keys.ml) | `sent: literal: $HOME; #{pane_id}` |
| Rename a window and retain the old observation | [Rename](../examples/showcase_rename_window.ml) | `renamed: editor-main` |
| Create a window and recapture its name | [Create](../examples/showcase_create_window.ml) | `created: logs` |
| Move a window to another session's index | [Move](../examples/showcase_move_window.ml) | `moved: build at 7` |
| Apply and verify horizontal pane geometry | [Layout](../examples/showcase_layout.ml) | `layout: 3 horizontal panes` |

All programs print their temporary socket path before the outcome. Run the
graph example; it traverses the snapshot after the client and daemon close:

```console
$ opam exec -- dune exec examples/showcase_graph.exe -- tmux
```

Observe future output with an application-owned Eio switch:

```console
$ opam exec -- dune exec examples/showcase_watch.exe -- tmux
```

Send a literal string containing shell and tmux format characters:

```console
$ opam exec -- dune exec examples/showcase_send_keys.exe -- tmux
```

Rename the editor window:

```console
$ opam exec -- dune exec examples/showcase_rename_window.exe -- tmux
```

Create a separate logs window:

```console
$ opam exec -- dune exec examples/showcase_create_window.exe -- tmux
```

Move a build window to index 7 in another session:

```console
$ opam exec -- dune exec examples/showcase_move_window.exe -- tmux
```

Split a window and apply an even horizontal layout:

```console
$ opam exec -- dune exec examples/showcase_layout.exe -- tmux
```

These examples support tmux 3.3a–3.8 on the qualified Linux environment.
The native CI job executes their real entry points on 3.3a and 3.8,
using a separate installation and Dune project. A nonzero exit, missing exact
outcome line, leftover directory or surviving owned process fails the run.
[`showcase.json`](../examples/showcase.json) records the whole files, commands,
expected lines, tmux floor, workflow, job and runner.

Sending keys confirms tmux accepted input. The rendered-text example observes
the resulting screen; it does not wait for an arbitrary application's exit
code. A future-byte subscription has no historical capture barrier. See
[control outcomes](control.md) and [streaming](streaming.md) for those contracts.
