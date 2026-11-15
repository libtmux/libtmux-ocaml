# docs_snippets

Checks that the documentation shows what the repository's examples execute,
and that its local links resolve.

## What it checks

The check reads `README.md`, `docs/*.md` and the package READMEs under `lib/`,
`unix/`, `eio/`, `json/`, `workspace/` and `cli/`. It fails on the first of
these:

- An `<!-- example: PATH#REGION -->` include whose code block differs from the
  source. `PATH` is relative to the repository root. `REGION` names the lines
  between `(* docs:begin REGION *)` and `(* docs:end REGION *)` in an `.ml`
  file, dedented. A `.json` include repeats the whole file and takes no region.
- A relative Markdown link, or a `src` or `srcset` asset, that points outside
  the repository or at a missing file.
- A link fragment into another Markdown file that names no heading there.
- Documentation with no example include at all.

The error names the document and the include or link. On success it prints
the number of includes and links it checked.

## Who runs it

CI runs it in the `quality` job of `.github/workflows/ocaml.yml`. Run it
locally after editing a README, a guide, or an example region they quote.
`test/installed_consumer.py` imports `snippet` to build the installed example
programs from the same regions.

## Run

The script needs only uv and the standard library. Run it from any directory:

```console
$ uv run scripts/docs_snippets/docs_snippets.py
```

Run its tests:

```console
$ uv run pytest scripts/docs_snippets
```

The tests run the check on this repository and on temporary trees built from
`check(root)`, which takes the repository root. Each rejection has a test that
fails when the matching check is removed.
