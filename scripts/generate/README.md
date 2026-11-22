# generate

Four generators keep checked-in OCaml and reference pages in step with the
tmux catalogs and the native `Operations` API. Each writes its files, or with
`--check` fails when a file differs from what it would write:

```text
generated file differs: lib/generated_fields.ml
```

- `generate_fields.py` reads `catalog/fields.json` and writes
  `lib/generated_fields.ml` and `docs/fields.md`.
- `generate_options.py` reads `catalog/releases.json` and
  `catalog/options.json` and writes `lib/option_catalog.ml` and
  `docs/options.md`.
- `generate_formats.py` reads `catalog/releases.json` and
  `catalog/formats.json` and writes `lib/format_catalog.ml` and
  `docs/formats.md`.
- `generate_operations.py` reads `lib/libtmux.mli` and `lib/commands.ml` and
  writes `catalog/operations.json`, `docs/operations.md`,
  `unix/generated_operations.ml` and `eio/generated_operations.ml`. It also
  rewrites the generated block of `unix/libtmux_unix.mli` and
  `eio/libtmux_eio.mli`.

Generated OCaml starts with a comment naming its generator. `emit.py` holds
what the four share: the `--check` and write driver, the `ocamlformat` call
and the list of supported tmux releases.

## Who runs it

CI runs every `--check` in the `quality` job of
`.github/workflows/ocaml.yml`. Run the matching generator, without `--check`,
after editing a catalog, `lib/libtmux.mli` or `lib/commands.ml`, then commit
the result.

## Run

The generators format OCaml with the `ocamlformat` version pinned in
`.ocamlformat`, so run them under `opam exec --`. They need no Python
dependencies. Check one generator:

```console
$ opam exec -- uv run scripts/generate/generate_fields.py --check
```

Regenerate its files:

```console
$ opam exec -- uv run scripts/generate/generate_fields.py
```

`generate_formats.py` and `generate_options.py` also recapture their catalog
from the exact tmux release sources, one `tmux-VERSION/` directory per release
under `DIR`. Do this outside check loops:

```console
$ opam exec -- uv run scripts/generate/generate_options.py --source-dir DIR
```

Run the tests:

```console
$ opam exec -- uv run --project scripts --locked pytest scripts/generate
```

The tests run each generator on the repository and on temporary copies of the
files it reads and writes. They show that a changed generated file, a missing
generated file and a changed catalog or interface are each reported, that write
mode restores the files, and that a catalog missing a supported release is
rejected.
