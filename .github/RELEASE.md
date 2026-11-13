# Release the OCaml packages

Push an annotated `vMAJOR.MINOR.PATCH` tag after its commit has merged into
`master`. The [Release workflow](workflows/release.yml) reruns the
[OCaml checks](workflows/ocaml.yml) on that exact commit, installs the source
archive outside the checkout, retains its checksums, publishes the archive on
GitHub and submits all package definitions to `ocaml/opam-repository`.

The first prepared version is `0.0.1`. All six packages share the version in
[dune-project](../dune-project): `libtmux`, `libtmux-unix`, `libtmux-eio`,
`libtmux-json`, `libtmux-workspace` and `libtmux-workspace-cli`. Keep their opam
files authored directly and their internal dependencies at `{= version}`.

An opam release becomes available after the metadata pull request passes
repository CI and a maintainer merges it. A GitHub Release or a successful
submission is not publication proof. See the
[official publication guide](https://ocaml.org/docs/publishing-packages-w-dune).

## One-time maintainer setup

Opam uses GitHub accounts and pull requests; no separate opam account or opam
API key is needed.

1. [Fork ocaml/opam-repository](https://github.com/ocaml/opam-repository/fork)
   into the GitHub account that will submit releases. Keep the fork public.
   The workflow discovers this account from the publishing token.
2. Create a [classic GitHub personal access token](https://github.com/settings/tokens)
   for that account with `public_repo` access and an expiration date. The token
   writes package definitions to the public fork and opens the upstream pull
   request. This workflow does not modify workflows in that fork.
3. Create the `opam` environment in the repository's
   [environment settings](https://github.com/libtmux/libtmux-ocaml/settings/environments).
   Restrict deployments to tags matching `v*`, and add a required reviewer if
   available. Protect release tags against replacement and deletion.
4. Add `OPAM_PUBLISH_TOKEN` as an environment secret. This command prompts for
   the token; do not put it in a command argument or commit it:

```console
$ gh secret set OPAM_PUBLISH_TOKEN \
    --repo libtmux/libtmux-ocaml \
    --env opam
```

The repository's automatic `GITHUB_TOKEN` uploads the GitHub archive. The
separate publishing token is available only in the `opam` job, after all
verification jobs pass. A missing token or fork stops that job before any
archive upload.

The archive and metadata generator is pinned to
[dune-release 2.3.0](https://github.com/tarides/dune-release/tree/2.3.0).
The GitHub CLI submits the retained definitions through the account's fork.
The documented opam submission path uses GitHub credentials. It does not
provide an OIDC trusted-publisher exchange. GitHub App or fine-grained token
compatibility has not been qualified for this workflow.

## Prepare and rehearse

For each release, update `(version ...)` in `dune-project` and add a nonempty
matching entry to [CHANGELOG.md](../CHANGELOG.md). Review package changelogs and
the [current support and qualification limits](../docs/status.md). Keep the
compiler and tmux endpoint policy in [CONTRIBUTING.md](CONTRIBUTING.md).

Open a preparation PR. Every OCaml CI run builds and tests the archive, generates
and lints all six opam definitions, installs the archived packages with opam,
checks their installed versions and runs the installed `tmux-workspace` command.
The rehearsal needs no publishing credential and performs no remote writes.

The rehearsal creates its annotated tag in a private temporary clone. It does
not add or replace tags in the source checkout. Its `opam-release-COMMIT` Actions
artifact contains the archive, package definitions, source identity, release
notes and `SHA256SUMS`; retention is 90 days.

Run the critical offline release checks locally:

```console
$ /usr/bin/time -p python3 .github/scripts/release_test.py
```

After this workflow has merged, request another complete rehearsal without
publication:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-ocaml \
    --ref master \
    --field publish=false
```

The reusable CI runs the pure suite, generated-file and format checks, public
interface export, installed consumers and native tests for tmux 3.3a and 3.8
using OCaml 5.5.2. A tag reruns those checks even when the same commit already
passed on `master`.

## Publish the first release

Complete account and secret setup, merge the preparation PR and require green
CI for the merged commit. The commands below start publication. They are
maintainer actions, not part of preparing the PR.

Set the intended version in the shell:

```console
$ export LIBTMUX_RELEASE_VERSION=0.0.1
```

```console
$ export LIBTMUX_RELEASE_TAG="v$LIBTMUX_RELEASE_VERSION"
```

Update `master` to the approved commit:

```console
$ git switch master
```

```console
$ git pull --ff-only origin master
```

Check the release identity and inspect its notes:

```console
$ python3 .github/scripts/release.py check \
    --tag "$LIBTMUX_RELEASE_TAG"
```

Create an annotated tag, then push only that tag:

```console
$ git tag \
    --annotate "$LIBTMUX_RELEASE_TAG" \
    --message "Release $LIBTMUX_RELEASE_VERSION"
```

```console
$ git push origin "refs/tags/$LIBTMUX_RELEASE_TAG"
```

Watch the [Release runs](https://github.com/libtmux/libtmux-ocaml/actions/workflows/release.yml).
Approve the `opam` environment deployment if configured. The publishing job
verifies the annotated tag, merged commit and retained checksums. It uploads
the fixed archive and submits all six definitions in one opam-repository pull
request. Follow the pull request URL in the submission step, address review
feedback and wait for its merge.

## Verify public availability

Run these commands only after the opam-repository pull request has merged.
Use the version variables from the publication steps above.

```console
$ opam update
```

Create an independent consumer switch:

```console
$ export LIBTMUX_RELEASE_CONSUMER="$(mktemp -d -t libtmux-ocaml-consumer.XXXXXX)"
```

```console
$ opam switch create "$LIBTMUX_RELEASE_CONSUMER" ocaml-base-compiler.5.5.2 \
    --no-switch \
    --yes
```

Install the public packages without a source pin:

```console
$ opam install \
    --switch "$LIBTMUX_RELEASE_CONSUMER" \
    --yes \
    "libtmux.$LIBTMUX_RELEASE_VERSION" \
    "libtmux-unix.$LIBTMUX_RELEASE_VERSION" \
    "libtmux-eio.$LIBTMUX_RELEASE_VERSION" \
    "libtmux-json.$LIBTMUX_RELEASE_VERSION" \
    "libtmux-workspace.$LIBTMUX_RELEASE_VERSION" \
    "libtmux-workspace-cli.$LIBTMUX_RELEASE_VERSION"
```

```console
$ opam exec \
    --switch "$LIBTMUX_RELEASE_CONSUMER" \
    -- tmux-workspace --help=plain
```

Remove only the consumer switch created above:

```console
$ opam switch remove "$LIBTMUX_RELEASE_CONSUMER" \
    --yes
```

After this check passes, update the source-install wording in the package
READMEs. Keep hosted documentation deployment and the remaining adoption
qualification gates separate from registry publication.

## Retry or recover a submission

If setup was missing, configure the secret or fork, then rerun the existing
Release run. To start a fresh run against an existing tag:

```console
$ gh workflow run release.yml \
    --repo libtmux/libtmux-ocaml \
    --ref "$LIBTMUX_RELEASE_TAG" \
    --field publish=true
```

Each run repeats verification. An existing GitHub archive must match the newly
verified bytes; the workflow refuses to overwrite it. It can attach a missing
archive to an existing public release, then retry opam submission. The workflow
updates an existing submission for the same release branch using a Git lease.
After an upstream merge, verify public availability instead of resubmitting
that version.

Preserve the original Actions artifact and published archive after any upload.
If a checksum differs, stop and inspect the retained files. Do not replace the
archive, move the tag or change an accepted opam checksum. Fix source defects
in a new version; follow the
[opam package correction policy](https://github.com/ocaml/opam-repository/blob/master/CONTRIBUTING.md#fixing-packages)
for metadata changes.
