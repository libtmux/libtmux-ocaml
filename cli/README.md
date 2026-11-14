<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../workspace/assets/logo.svg" type="image/svg+xml">
    <img src="../workspace/assets/logo-128.png" width="128" height="128" alt="libtmux workspace for OCaml">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for OCaml

**libtmux-workspace-cli · JSON workspace commands**

</div>

Validate JSON workspace files, preview their plans and create tmux sessions,
windows and panes with `tmux-workspace`. This package installs a command-line
application built on the [workspace library](../workspace/),
[JSON codec](../json/) and native clients.

[Command guide](../docs/workspaces.md) ·
[Workspace API](https://libtmux.org/en/ocaml/latest/workspace/reference/) ·
[Examples](#install-and-validate) ·
[Configuration example](../examples/workspace/project.json) ·
[Recovery](../docs/workspace-recovery.md) ·
[Compatibility](../docs/compatibility.md)

## Install and validate

Follow the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2 on Linux**. `opam install .` includes the CLI; there is no opam
release yet. Run the following commands from the repository root.

Validate the shipped configuration without starting or contacting tmux:

```console
$ opam exec -- tmux-workspace check examples/workspace/project.json
```

```text
Valid workspace "ocaml-project": 2 windows, 3 panes
```

List the subcommands and their options:

```console
$ opam exec -- tmux-workspace --help=plain
```

## Define the workspace

The checked [project.json](../examples/workspace/project.json) describes two
windows and three panes. Each pane runs `/bin/cat -u` through literal argv.
Relative working directories resolve against the JSON file's directory.
The CLI decodes this document through [`Libtmux_json.Workspace`][json-workspace],
then uses [`Plan`][plan] and the [Eio workspace executor][eio-workspace] to apply it.

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

## Preview and apply explicitly

| Command | Result | tmux effects |
| --- | --- | --- |
| `check` | Validate the document; `--json` includes its digest | None |
| `plan` | Observe an explicit socket and print an advisory plan | Never starts a daemon |
| `apply` | Read the document again, check current state and execute a fresh plan | Creates and configures resources |

`plan` and `apply` require `--socket`. Connections support **tmux 3.3a–3.8**
and require Linux pidfds, the daemon's PID namespace and a shared local
filesystem. With `--require-existing`, a missing endpoint fails instead of
bootstrapping a session. Closing the CLI's client leaves the daemon running.

Follow the [complete workspace walkthrough](../docs/workspaces.md#validate-preview-and-apply)
to copy the configuration into a private directory, start an isolated server,
apply it, verify `editor:2` and `logs:1`, and remove only the created resources.

## Inspect failures before retrying

`--json` emits a versioned result or execution receipt. Invalid input exits 2;
a collision, changed document or stale plan exits 4; partial or uncertain apply
exits 5. The [exit-code reference](../docs/workspaces.md#collisions-and-recovery)
lists the remaining cases.

An existing session name is rejected by default. `--append` adds new windows
without changing existing session settings. Failed or interrupted applies
compensate only proven creations; `--keep-partial` retains them. Inspect the
receipt before another mutation. Cancellation does not undo commands already
written, and a receipt does not provide crash-durable recovery or replay authority.

[Workspace library](../workspace/) · [JSON codec](../json/) ·
[Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[json-workspace]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_json-workspace/
[plan]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-plan/
[eio-workspace]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_eio-workspace/
