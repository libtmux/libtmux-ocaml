# Contributing

This repository is a metadata scaffold. Native checks validate package
definitions; library installation and tmux behavior await implementation.

Read [AGENTS.md](../AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Toolchain

[.tool-versions](../.tool-versions) pins opam. [libtmux.opam](../libtmux.opam)
pins OCaml and Dune for initial development. These are development choices;
compiler and platform compatibility remain unverified.

The compiler policy is current stable OCaml only, using 2026 releases. Keep
the compiler dependency exact and replace it when adopting a newer stable
release. Older OCaml versions, backports, and compatibility matrices for them
are outside the project scope.

The initial versions were checked against the upstream releases:
[opam 2.6.1](https://github.com/ocaml/opam/releases/tag/2.6.1),
[OCaml 5.5.2](https://github.com/ocaml/ocaml/releases/tag/5.5.2), and
[Dune 3.24.2](https://github.com/ocaml/dune/releases/tag/3.24.2).

Install the pinned opam with mise, outside the validation loops:

```console
$ mise install opam
```

The opam lint check below needs neither initialization nor a compiler switch.
For Dune checks, initialize opam if needed without changing shell startup files:

```console
$ mise exec -- opam init \
    --bare \
    --no-setup
```

Create a local switch with an exact compiler constraint and the dependencies
declared in `libtmux.opam`. Keep the compiler argument below aligned with that
manifest. This installs dependencies into the ignored `_opam/` directory and
leaves the default switch unchanged. Run setup outside validation loops:

```console
$ mise exec -- opam switch create \
    --deps-only \
    --no-switch \
    . ocaml-base-compiler.5.5.2
```

## Metadata checks

Check the native manifest offline:

```console
$ /usr/bin/time -p mise exec -- opam lint libtmux.opam
```

With the local switch prepared, validate the Dune package definition in the
outer loop:

```console
$ /usr/bin/time -p mise exec -- opam exec -- dune build \
    -p libtmux
```

Check tracked edits for whitespace errors:

```console
$ git diff --check
```

Git diff omits untracked files. Inspect new files separately and check the
staged diff when preparing an authorized commit:

```console
$ git diff --cached --check
```

Keep `libtmux.opam` as the source of package metadata. The `allow_empty` package
setting in `dune-project` permits the metadata scaffold; remove it when the
first library or executable is added. An empty build is not implementation
or installed-package evidence.

## Validation loops

Measure the whole command, including startup and setup. Libraries should aim
for the stretch budgets.

| Loop | Budget | Stretch | When | Scope |
| --- | --- | --- | --- | --- |
| Inner | Under 5 seconds | Under 2 seconds | Every edit | Checks for changed critical behavior |
| Mid | Under 30 seconds | Under 10 seconds | After each change and before handoff | Unit suites, lint, generated-file checks |
| Outer | Under 5 minutes | Under 60 seconds | Before a commit or PR | Types, builds, integration, installed packages, matrices |

Keep network access, installs, production builds, browsers, sleeps, and broad
corpus scans out of the inner and mid loops. Treat a timeout or wait over one
second as a structural bug: investigate it and use events or subscriptions.
Tag slow tests with a one-line reason and place them in the outer loop.
Fix over-budget loops before adding tests; do not raise the budget.

Benchmarks are separate. Keep each run under ten minutes and a full sweep
under one hour; reduce workloads when necessary.

## Future tmux checks

Every test or probe must use a unique owned socket and temporary directory,
with a `libtmux-ocaml-` prefix. Clear inherited `TMUX` and `TMUX_PANE` for child
commands and address the socket explicitly. Clean up only resources created
by that run and verify that its processes exit. Never use or stop the default
tmux server.

Record exact OCaml, Dune, tmux, and OS versions. A passing subset does not
establish a compatibility matrix. Test examples as shipped, including imports,
output assertions, and cleanup.

## Pull requests

Keep each commit focused on one subject. Inspect the complete diff, preserve
unrelated changes, and stage explicit paths. Describe the problem, resulting
behavior, validation commands and durations, and remaining limitations.

Do not claim an API, platform, or release until it exists and has been verified.
