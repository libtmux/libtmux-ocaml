<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-128.png" width="128" height="128" alt="libtmux workspace for OCaml">
  </picture>

# libtmux workspace for OCaml

**libtmux-workspace · native configuration and planning**

</div>
<!-- /libtmux-logo -->

Validate workspace descriptions and preview their actions with
`Libtmux_workspace`. The package depends on the pure [core](../lib/) and the
OCaml standard library. Add the [JSON codec](../json/) to read configuration
documents, or a [blocking](../unix/) or [Eio](../eio/) client to create sessions,
windows and panes.

[API](https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace/) ·
[Workspace guide](../docs/workspaces.md) · [Workspace CLI](../cli/) ·
[Package boundaries](../docs/packages.md)

## Use from OCaml

Follow the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2**. There is no opam release yet. Link `libtmux-workspace` alongside
`libtmux` in your Dune application.

| Module | Use | I/O |
| --- | --- | --- |
| `Config` | Validate names, paths, argv, settings and layout descriptions | None |
| `Plan` | Describe actions against a captured graph or an observed missing endpoint | None |
| `Execution` | Retain creations, uncertainty and compensation outcomes | Through an explicit executor |

The [native bootstrap walkthrough](../docs/bootstrap.md) shows a complete
builder and client program. The [interruption example](../docs/workspace-recovery.md)
retains its execution handle outside cancellation, inspects the journal after
client cleanup and checks compensation. The journal lives in process memory;
a saved receipt does not resume a later execution or authorize a retry.

## Use from the command line

The [libtmux-workspace-cli](../cli/) package installs `tmux-workspace` for JSON
configurations. It uses this library for validation, plans and execution.

After following the [source installation](../README.md#install-from-source), run
this from the repository root to validate the shipped configuration without
contacting tmux:

```console
$ opam exec -- tmux-workspace check examples/workspace/project.json
```

Expected output: `Valid workspace "ocaml-project": 2 windows, 3 panes`.

See the [core README](../README.md) for the graph and query APIs, and
[current limits](../README.md#packages-and-current-limits) before adopting the
complete automation suite.

The [workspace guide](../docs/workspaces.md) covers the JSON format, explicit
endpoints, bootstrap, collision policies, exit codes and partial-failure recovery.

[JSON codec](../json/) · [Changelog](CHANGELOG.md) · [MIT](../LICENSE)
