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
[`Libtmux_workspace`][api]. The package depends on the pure [core](../lib/) and the
OCaml standard library. Add the [JSON codec](../json/) to read configuration
documents, or a [blocking](../unix/) or [Eio](../eio/) client to create sessions,
windows and panes.

[API](https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace/) ·
[Examples](#preview-a-native-workspace) ·
[Workspace guide](../docs/workspaces.md) · [Workspace CLI](../cli/) ·
[Package boundaries](../docs/packages.md)

## Use from OCaml

Follow the [source installation](../README.md#install-from-source) with
**OCaml 5.5.2**. There is no opam release yet. Link `libtmux-workspace` alongside
`libtmux` in your Dune application.

| Module | Use | I/O |
| --- | --- | --- |
| [`Config`][config] | Validate names, paths, argv, settings and layout descriptions | None |
| [`Plan`][plan] | Describe actions against a captured graph or an observed missing endpoint | None |
| [`Execution`][execution] | Retain creations, uncertainty and compensation outcomes | Through an explicit executor |

## Preview a native workspace

### [`Plan.make`][plan-make]: preview actions without tmux I/O

[`Config.make`][config-make] validates the description; [`Plan.make`][plan-make]
builds an ordered preview. This complete program performs no tmux or filesystem
I/O. The absolute directory and socket paths describe a prospective endpoint;
`observed:None` explicitly models it as missing.

In a separate application, create `dune-project` containing `(lang dune 3.24)`.
Copy the program as `workspace_plan.ml` and use this `dune` file:

```dune
(executable
 (name workspace_plan)
 (libraries libtmux libtmux-workspace))
```

<!-- example: examples/workspace_plan.ml -->

```ocaml
open Libtmux
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan

let checked pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let () =
  let spawn = Spawn.make (Exec { program = "cat"; args = [] }) in
  let config =
    Config.make ~directory:"/srv/project" ~session:"project"
      [
        Config.window ~name:"editor"
          [
            Config.pane ~spawn ();
            Config.pane ~spawn ~direction:Geometry.Right ();
          ];
        Config.window ~name:"logs" [ Config.pane ~spawn () ];
      ]
    |> checked Config.pp_error
  in
  let plan =
    Plan.make
      ~endpoint:(Endpoint.socket_path "/srv/project/tmux.sock")
      ~version:"3.8" ~observed:None config
    |> checked Plan.pp_error
  in
  Printf.printf "%s: %d windows, %d actions\n" (Config.session config)
    (Iarray.length (Config.windows config))
    (Iarray.length (Plan.actions plan))
```

After source installation, run the shipped program from the checkout root:

```console
$ opam exec -- dune exec examples/workspace_plan.exe
```

```text
project: 2 windows, 3 actions
```

[`Plan.actions`][plan-actions] contains session creation, pane splitting and
window creation. To execute a plan, choose the [blocking][unix-workspace] or
[Eio][eio-workspace] workspace adapter explicitly.

The [native bootstrap walkthrough](../docs/bootstrap.md) shows a complete
builder and client program. The [interruption example](../docs/workspace-recovery.md)
retains its execution handle outside cancellation, inspects the journal after
client cleanup and checks compensation. The journal lives in process memory;
a saved receipt does not resume a later execution or authorize a retry.

## Use from the command line

### [`tmux-workspace check`](../docs/workspaces.md#validate-preview-and-apply): validate a JSON workspace

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

[config-make]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-config-make/
[plan-make]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-plan-make/
[plan-actions]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-plan-actions/
[unix-workspace]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_unix-workspace/
[eio-workspace]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_eio-workspace/
[api]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace/
[config]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-config/
[plan]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-plan/
[execution]: https://libtmux.org/en/ocaml/latest/workspace/reference/libtmux_workspace-execution/
