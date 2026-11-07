# libtmux-ocaml

Scaffold for a standalone OCaml interface to tmux. The repository contains
package metadata and contributor instructions. No library, CLI, tests, or
release exists yet.

The native package name is `libtmux`. [libtmux.opam](libtmux.opam) owns package
metadata and pins the initial OCaml and Dune toolchain.
[.tool-versions](.tool-versions) pins opam. These pins do not establish a
tested compatibility range.

Target only the latest stable OCaml release in 2026. Older compiler versions
are out of scope. As stable releases advance, replace the exact compiler pin
and validate the new target.

See [CONTRIBUTING.md](.github/CONTRIBUTING.md) for setup and metadata checks,
[WRITING.md](.github/WRITING.md) for prose and commit conventions, and
[AGENTS.md](AGENTS.md) for agent instructions.

Licensed under the [MIT License](LICENSE).
