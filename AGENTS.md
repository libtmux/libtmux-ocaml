# Agent instructions

This is the native OCaml libtmux library. Read [README.md](README.md),
[dune-project](dune-project), and [libtmux.opam](libtmux.opam) before editing.
Follow the active implementation epic and retain its remaining acceptance gates.

## Policies

- Setup, checks, tmux isolation, and pull requests:
  [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).
- Documentation, comments, and commit messages:
  [.github/WRITING.md](.github/WRITING.md).

Each guide owns its subject. `CLAUDE.md` is a relative symlink to this file.

## Change discipline

- Inspect Git state and preserve unrelated work and existing symlink targets.
- Use `rg`, `ag`, or `fd` for searches and `jq` for JSON.
- Make the smallest coherent change. Reuse existing helpers and keep APIs
  private until an external caller needs them.
- Add files for distinct responsibilities or independent reuse, not one-line
  re-exports or single-use wrappers.
- Follow native OCaml conventions. Other ports provide behavioral references;
  their implementation and test results do not establish OCaml support.
- Target only the latest stable OCaml release in 2026. Verify upstream releases
  before replacing the exact compiler pin in `libtmux.opam`. Do not add
  backports, compatibility shims, or older-compiler test matrices unless
  explicitly requested.
- Keep `libtmux.opam` authored directly; it is not generated from Dune.
- Add tests only for critical behavior. Avoid tests that repeat implementation.
  Confirm that a regression test fails for the original defect before relying
  on its passing result.
- Report commands, whole-command durations, failures, and skipped checks.
  Distinguish `PASS`, `FAIL`, `PARTIAL`, and `UNVERIFIED`.
- Bootstrap scope covers local metadata and instructions. Commits, remote
  changes, pushes, and publication require current authorization.
