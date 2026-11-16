# toolchain

Checks that the OCaml compiler, dune and opam on `PATH` are the versions the
repository pins.

## What it checks

`check_toolchain.py` reads the exact `ocaml` and `dune` versions from the
`depends` of `libtmux.opam` and the `opam` version from `.tool-versions`. It
runs `opam exec -- ocamlc -version`, `opam exec -- dune --version` and
`opam --version`, and exits 1 with one line per tool whose version differs. A
pin that is missing or not an exact `{= "VERSION"}` constraint is an error.

## Who runs it

CI runs it in the `quality` job of `.github/workflows/ocaml.yml` after the
development dependencies install. Run it locally after changing a pin.

## Run

The script needs uv, opam and the standard library:

```console
$ uv run scripts/toolchain/check_toolchain.py
```

Run its tests:

```console
$ uv run pytest scripts/toolchain
```

The tests build pin files in temporary directories and replace the version
commands with fakes, so they need no opam switch.
