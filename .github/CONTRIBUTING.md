# Contributing

This repository implements the pure core first. Client and consumer work has
separate acceptance gates; a passing core test does not qualify a transport.

Read [AGENTS.md](../AGENTS.md) for change discipline and
[WRITING.md](WRITING.md) for prose and commit conventions.

## Toolchain

[.tool-versions](../.tool-versions) pins opam. [libtmux.opam](../libtmux.opam)
pins OCaml and Dune for development. The current packages build with this
compiler; [compatibility evidence](../docs/compatibility.md) records the
qualified runtime components and remaining gates.

The compiler policy is current stable OCaml only, using 2026 releases. Keep
the compiler dependency exact and replace it when adopting a newer stable
release. Older OCaml versions, backports, and compatibility matrices for them
are outside the project scope.

Dependency and GitHub Actions upgrades are reviewed manually. Do not add
scheduled Dependabot or Renovate version-update PRs. Keep security alerts
enabled; automatic security-fix PRs are a separate, currently disabled setting.
GitHub's [supported Dependabot ecosystems][dependabot-ecosystems] do not include
opam, so this setting does not establish coverage for OCaml dependencies.

[dependabot-ecosystems]: https://docs.github.com/en/code-security/reference/supply-chain-security/supported-ecosystems-and-repositories

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
    --with-test \
    --with-doc \
    . ocaml-base-compiler.5.5.2
```

Install the development formatter separately from runtime dependencies:

```console
$ mise exec -- opam install ocamlformat.0.29.0
```

## Checks

Check the native manifest offline:

```console
$ /usr/bin/time -p mise exec -- opam lint libtmux.opam
```

With the local switch prepared, validate the Dune package definition in the
outer loop:

```console
$ /usr/bin/time -p mise exec -- opam exec -- dune build \
    @all @install @doc
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

Keep `libtmux.opam` as the source of package metadata.

Run the pure unit, property and public compile-failure checks:

```console
$ /usr/bin/time -p mise exec -- opam exec -- dune runtest
```

The suite also includes test-only `ppx_expect` diagnostics alongside typed
Alcotest assertions. See [testing and CI](../docs/testing.md) for failure
presentation, property cases and cached native builds.

Check generated field descriptors and documentation:

```console
$ /usr/bin/time -p mise exec -- opam exec -- python3 tools/generate_fields.py --check
```

Verify installation from an independent temporary consumer in the outer loop:

```console
$ /usr/bin/time -p mise exec -- opam exec -- python3 test/installed_consumer.py
```

Check generated versioned option and hook descriptors:

```console
$ /usr/bin/time -p mise exec -- opam exec -- python3 tools/generate_options.py --check
```

Check generated format availability and backend convenience APIs:

```console
$ /usr/bin/time -p mise exec -- opam exec -- python3 tools/generate_formats.py --check
```

```console
$ /usr/bin/time -p mise exec -- opam exec -- python3 tools/generate_operations.py --check
```

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

## Owned tmux fixtures

Build the exact Linux release fixtures outside validation loops:

```console
$ python3 tools/setup_tmux.py 3.3 3.3a 3.4 3.8 3.2a
```

Verify fixture cleanup after success, failure and cancellation:

```console
$ /usr/bin/time -p python3 test/fixture_test.py \
    scratch/tmux/tmux-3.3/tmux \
    scratch/tmux/tmux-3.3a/tmux \
    scratch/tmux/tmux-3.4/tmux \
    scratch/tmux/tmux-3.8/tmux
```

The 3.2a binary is retained for unsupported-version checks. Fixture success
alone does not establish library compatibility on any release.

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
