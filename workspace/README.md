<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="assets/logo.svg" type="image/svg+xml">
    <img src="assets/logo-128.png" width="128" height="128" alt="libtmux workspace for OCaml">
  </picture>

# libtmux workspace for OCaml

</div>
<!-- /libtmux-logo -->

Validate a workspace, preview its plan, and create its tmux sessions, windows and
panes through the blocking or Eio client. The `libtmux-workspace-cli` package
installs `tmux-workspace` for JSON configurations.

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
