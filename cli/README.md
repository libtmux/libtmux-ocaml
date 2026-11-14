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

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/ocaml/latest/workspace/)

</div>

Validate JSON workspace files, preview their plans and create tmux sessions,
windows and panes with `tmux-workspace`. Built on the
[workspace library](../workspace/), [JSON codec](../json/) and native clients.

[Command guide](../docs/workspaces.md) ·
[Workspace API](https://libtmux.org/en/ocaml/latest/workspace/reference/) ·
[Examples](#install-and-validate) ·
[Configuration example](../examples/workspace/project.json) ·
[Recovery](../docs/workspace-recovery.md) ·
[Compatibility](../docs/compatibility.md)

## Install and validate

Not on opam yet: follow the [source install](../README.md#install-from-source);
`opam install .` includes the CLI. Linux only. Run the commands below from the
checkout root.

### [`tmux-workspace check`](../docs/workspaces.md#validate-preview-and-apply): validate without contacting tmux

Check the shipped configuration:

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

[project.json](../examples/workspace/project.json) describes two windows and
three panes, each running `/bin/cat -u` as literal argv. Relative directories
resolve against the file's directory.
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

### [`tmux-workspace apply`](../docs/workspaces.md#validate-preview-and-apply): execute a fresh plan

| Command | Result | tmux effects |
| --- | --- | --- |
| `check` | Validate the document; `--json` includes its digest | None |
| `plan` | Observe an explicit socket and print an advisory plan | Never starts a daemon |
| `apply` | Read the document again, check current state and execute a fresh plan | Creates and configures resources |

- `plan` and `apply` require `--socket`. Needs tmux 3.3a or newer and a local
  daemon.
- `--require-existing` fails on a missing endpoint instead of starting a session.
- Closing the CLI's client leaves the daemon running.

More: the [full walkthrough](../docs/workspaces.md#validate-preview-and-apply)
starts a private server, applies the file, verifies `editor:2` and `logs:1`,
and cleans up.

## Inspect failures before retrying

- `--json` emits a versioned result or receipt.
- Exit 2: invalid input. Exit 4: collision, changed document or stale plan.
  Exit 5: partial or uncertain apply.
  [All exit codes](../docs/workspaces.md#collisions-and-recovery).
- An existing session name is rejected; `--append` adds windows and leaves
  session settings alone.
- A failed or interrupted apply undoes only proven creations; `--keep-partial`
  keeps them.
- Read the receipt before mutating again. It cannot replay or recover a crashed
  run, and cancellation does not undo written commands.

[Workspace library](../workspace/) · [JSON codec](../json/) ·
[Changelog](CHANGELOG.md) · [MIT](../LICENSE)

[json-workspace]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_json-workspace/
[plan]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-plan/
[eio-workspace]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_eio-workspace/
