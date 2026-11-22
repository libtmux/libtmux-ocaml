# Writing

This file adds OCaml, Dune, `odoc`, and multi-package rules to
[`libtmux/.github/WRITING.md`][org-writing], which governs voice, plain
CommonMark, 80-column repository wrapping, unwrapped issue and pull-request
bodies, slop removal, and commit and pull-request format.
[CONTRIBUTING.md](CONTRIBUTING.md) governs setup and validation loops.

Distinguish planned, implemented, tested, and published behavior. Answer
questions before editing. When responding to feedback, say whether you agree or
disagree before describing changes.

## Code blocks

- Put one paste-and-run command in each block; an explicit continuation or
  chain counts as one command.
- Mark shell commands as `console`, prefix commands with `$ `, and split long
  commands with `\` and one flag per continuation line.
- Put explanations outside the block and use the language tag for source code.
- Use repository-relative links for tracked files and verify their targets.

## Examples

<!-- shared:examples -->

An example is code written for a reader: a program under `examples/`, code in
a doc comment or docstring, and every fenced block in a README or docs page.
Shell blocks also follow [Code blocks](#code-blocks).

The text between the shared markers is the same in every libtmux port.
Change it in all of them together.

### Width

- **Examples stay within 80 columns.** They render in fixed-width boxes that
  scroll sideways, and 80 columns fits a libtmux.org code block in a
  laptop-width window. Comments inside examples wrap at 80 too.
- **The width check enforces it.** It reads the tracked files that
  `.github/example-width.toml` names and fails on a wider line. It measures
  the whole source line, so code in a doc comment counts its indent and
  comment marker. It skips output (a fence tagged `text`, and what a
  `console` block prints), hidden setup lines, and a line that is only a URL;
  an untagged fence counts as code.
- **A line that must stay wider is listed there with its reason.** An entry
  that no longer matches a line fails the check, so no stale entry stays.
- **The formatter's width is the hard limit for all other source.** Example
  directories set their formatter to 80 where the formatter takes a width.

### Reaching 80

- **Change the code, not the line breaks.** A formatter rejoins any line that
  fits its width. Name a sub-expression, use a short example name, hide setup
  the reader does not need, or print less.
- **Break at the outermost level when a break is still needed:** after an
  opening parenthesis with one argument per line, one call per line in a
  chain, one field per line in a literal.
- **Put a comment on its own line above the code it explains.** Never trail
  one after code in an example, unless the repository's example runner reads
  it there, as with an assertion marker.
- **Break a long string at a word boundary,** never inside a tmux format
  (`#{...}`) or an escape sequence; the joined text stays the same.
- **Continue a long command in a `console` block the way its shell does:**
  `\` after a `$ ` prompt, a backtick after `PS> `, one flag per continuation
  line.

### What never breaks

- **Output a test compares.** Wrapping it changes what the test expects.
- **A block copied from a source file.** Fix the width in the source and run
  the sync command; never edit the copy.
- **Marker lines and URLs,** which tools and readers take whole.

<!-- /shared:examples -->

### In this repository

- **Hard limit:** examples stay within 80 columns, enforced by the
  `check-example-width` action of `libtmux/.github`,
  `.github/example-width.toml`, and `.ocamlformat` (`margin = 80`, checked by
  `dune build @fmt`).
- **Not formatted:** Markdown fences, `examples/workspace/*.json`, and `odoc`
  or MDX `{[ ... ]}` blocks in `.mli` and `.mld` files are not rewritten by
  `ocamlformat`; keep displayed code lines within 80 columns by hand.
- **Runs, compiles, exempt:** `dune build @all` compiles every program under
  `examples/`, MDX runs pure `{[ ... ]}` blocks in `dune runtest`, and the
  installed-consumer and showcase drivers run effectful programs against real
  tmux. Fences tagged `text` and stdout lines in `console` blocks are output.
- **Compared output and copied blocks:** keep asserted stdout lines intact.
  Edit source files under `examples/` first, run `dune build @fmt`, and keep
  `<!-- example: ... -->` blocks synced so
  `uv run scripts/docs_snippets/docs_snippets.py` passes. The counterexample
  below demonstrates width enforcement and is listed in
  `.github/example-width.toml`.

Bad, over 80:

```ocaml
  get (Client.set_environment client Environment.Global ~name:"LIBTMUX_DEMO" "one");
```

Good, name the scope and variable:

```ocaml
  let global = Environment.Global and name = "LIBTMUX_DEMO" in
  get (Client.set_environment client global ~name "one");
```

## README and task guides

Use the title **libtmux for OCaml**. Lead with the reader's task, installation,
the smallest complete working program, its result, and operational limits. Keep
one source-install route until an opam release has been verified. Support and
performance claims refer to the exact checked source and workload; do not infer
a release policy from another port's warning text.

Give every public package, including the workspace CLI, its own README in its
source directory. State its purpose, installation, a working example, limits,
and links to its API or command guide, changelog, license, and companion
packages. Reuse the library or workspace logo at the top through a relative
`assets/` path without copying the image set. Include package READMEs in the
documentation snippet and local-link checks.

A README is scanned, not read:

- A section is a task. Its `###` heading is the API linked to its reference
  page, followed by a colon and its job in plain words.
- Under the heading: a line or two, the tested example, what it prints, at most
  one note, and a `More:` link to the owning guide.
- Keep paragraphs to three lines or fewer, turn lists of facts into bullets,
  and omit feature inventories and check-runner boilerplate.
- State requirements as floors a reader can act on (`tmux 3.3a or newer`);
  toolchain pins and CI matrices stay in their own files.
- Root `README.md` shows queries, the query planner, and subscriptions under
  linked headings, then closes with `What it leaves out`, `Support and status`,
  compact reference links, and the `libtmux.org` family link.

## Executable examples

Edit source examples first. Derive snippets or check their exact source regions,
and compile and execute the complete programs through installed public packages.
Imports, entry points, and required inputs belong in the shown setup, with a
private server (`with_private_daemon`) and library cleanup rather than shell
`tmux` setup or `rm`.

A core capability showcase needs its own complete program, normally under 150
lines, recorded in `examples/showcase.json` and executed in CI. Clear inherited
tmux context in test runners, and remove only resources the example created.

## OCaml API documentation

Document public modules and declarations in their `.mli` interfaces using
native `odoc` comments. The first sentence states a caller-visible result and
stands on its own. Use `[code]` for code and `{!Identifier}` for resolvable API
links; use typed references when a type and value share a name, and link module
introductions to their owning guides with `odoc` URL links. Cross-package
references must resolve without turning an optional backend into a core runtime
dependency. Check both native `odoc` and shared-site HTML anchors.

State whether an operation performs I/O, what a result means, and relevant
defaults, bounds, ordering, multiplicity, ownership, cancellation, admission,
and failure behavior. Use MDX for executable pure examples and installed
real-tmux programs for effectful tasks. Edit source interfaces and regenerate
rather than hand-editing generated backend copies.

Comments in `.ml` and `.mli` source state only invariants, protocol constraints,
or non-obvious choices that the code cannot express itself.

## Commits and reviews

Follow `scope(type[detail]): concise description` (50-character subject,
72-character body lines, `why:` and `what:` separated by a blank line) and the
review and release rules in [`libtmux/.github/WRITING.md`][org-commits]. Keep
scopes lowercase unless they name a proper product or class, omit emoji and
attribution trailers, and do not invent release versions, dates, or install
commands.

[org-writing]: https://github.com/libtmux/.github/blob/main/WRITING.md
[org-commits]: https://github.com/libtmux/.github/blob/main/WRITING.md#commits-and-pull-requests
