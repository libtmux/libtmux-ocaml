# Choose the packages your application needs

This repository is one Dune project with separately installable opam packages.
Each package has an authored manifest. Internal dependencies require the same
package version, so a client or workspace adapter uses its matching core.

The core and pure workspace library have no third-party runtime dependencies.
They use only the OCaml standard library, including `Iarray`, `Seq`, `List` and
`result`. Test and documentation tools are development dependencies.

| Package | Role | Runtime dependencies |
| --- | --- | --- |
| `libtmux` | Immutable graph, typed queries, commands and observation values | OCaml standard library |
| `libtmux-workspace` | Pure configuration validation, plans and execution journals | `libtmux` |
| `libtmux-unix` | Blocking Linux transport and workspace executor | Core, workspace, standard `Unix`, private Linux bindings |
| `libtmux-eio` | Concurrent transport and workspace executor | Core, workspace, blocking transport, Eio |
| `libtmux-json` | Validated query and workspace JSON codecs | Core, workspace, Yojson |
| `libtmux-workspace-cli` | Installed `tmux-workspace` command | The libraries above, Eio's entry point and Cmdliner |

Pure workspace planning depends on captured observations and an explicit tmux
version. It does not start a scheduler, read files or contact tmux. Execution
uses the adapter supplied by `Libtmux_unix.Workspace` or `Libtmux_eio.Workspace`.
The CLI combines file loading, JSON decoding, planning and the Eio executor.

An application querying a captured graph needs only `libtmux`. A blocking
script chooses `libtmux-unix`; an Eio application chooses `libtmux-eio` and owns
its scheduler and switch. Add `libtmux-json` for external query documents or JSON
workspaces. These integrations do not add dependencies to the pure core.

See [installation](getting-started.md), [workspace examples](workspaces.md) and
[public interfaces](api.md). The source-install walkthrough installs all current
packages; a consuming Dune project lists only the libraries it uses.

## Scope policy

Prefer standard-library types and ordinary functions. Keep transport, JSON and
CLI dependencies at their integration boundaries. Target the current stable
OCaml; older-compiler shims and compatibility matrices are out of scope.

Native OCaml APIs and the workspace CLI are the project's automation
interfaces.
