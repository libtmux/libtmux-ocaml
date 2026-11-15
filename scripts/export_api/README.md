# export_api

Exports the public OCaml interfaces as one JSON artifact for the shared
documentation site. It wraps `tools/api_export.exe`, an OCaml program that reads
compiled `.cmti` files, and adds provenance and consistency checks.

The OCaml exporter (`tools/api_export.ml`, `tools/api_doc.ml`,
`tools/dune`) and the module manifest (`tools/api_modules.json`) stay in
`tools/`. The shared documentation workflow builds the executable from there
and reads the manifest.

## What it checks

For each module in `tools/api_modules.json`, the script fails unless:

- the interface source bytes equal their bytes at the library revision
  (`--revision`, default `HEAD`);
- the interface's `.cmti` appears in the package's Dune `.install` file;
- the exporter output has unique symbol identities, only `exported` symbols,
  and no private (`__`) module names.

The artifact records the library revision, the SHA-256 of every input and the
exporter's own files. The exporter revision is `null` when any exporter file
differs from `HEAD`.

## Who runs it

CI runs it in the `quality` job of `.github/workflows/ocaml.yml`. Maintainers
run it to preview what the shared site receives.

## Run

Build the optional exporter and the installed interfaces. The Dune stanza is
disabled unless `LIBTMUX_API_EXPORT=1`:

```console
$ LIBTMUX_API_EXPORT=1 opam exec -- dune build @install tools/api_export.exe
```

Write the artifact:

```console
$ opam exec -- uv run scripts/export_api/export_api.py \
    --output _build/docs/ocaml.json
```

Run the tests. Those that need no OCaml build use temporary Git repositories
and a stub exporter:

```console
$ uv run pytest scripts/export_api
```

Run the compiler-backed extraction tests as well. They compile fixture
interfaces and run the built exporter, so they need `ocamlc` on `PATH`:

```console
$ LIBTMUX_API_EXPORT=1 opam exec -- uv run pytest scripts/export_api
```
