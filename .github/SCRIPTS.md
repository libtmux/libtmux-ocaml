# Scripts

This policy covers the support scripts in this repository: files under
`scripts/`, CI helpers, generators and checkers. It applies the libtmux
decision in [libtmux/docs#323](https://github.com/libtmux/docs/pull/323).

## Keep a script only for a current use

A script stays when this project runs it today: a CI job, a release step, a
code generator, a documentation check, or a maintainer task named in
[CONTRIBUTING.md](CONTRIBUTING.md).

- Parity with Python libtmux or tmuxp is not a use. Delete comparison
  harnesses, oracles, ledgers and generated fixtures, and the CI steps that
  install them.
- A shell step that creates, prepares or stops tmux for an example or test
  means the library lacks an operation. File an issue for the operation and
  remove the step when it lands.
- Delete scripts nothing calls.
- Tooling several ports share lives once, as a shared workflow or action, not
  as a vendored copy.

## Language

Scripts are Python: the library has no Python dependency, and a small typed
script costs less than a second build system for tooling. Declare dependencies
inline (PEP 723) and run scripts with `uv run`.

## Layout and checks

- A script with tests lives in `scripts/<name>/`, with a `README.md` (what it
  does, who runs it, how) and `tests/`. A short single-purpose script may be
  one file with a usage header.
- Scripts pass `ruff format`, `ruff check`, `ty check` and `pytest`, with
  `pytest-asyncio` for async code and doctests collected, in CI.
- Use current language and tool idioms; no shims below the project's floor.
- Before a new or rewritten script merges, a reviewer who did not write it
  checks it against [WRITING.md](WRITING.md) and
  [no-ai-slop](https://github.com/petergyang/no-ai-slop).

## What stays

- GitHub Actions `run:` lines that call one command.
- Test data that is not a comparison, such as workspace files a loader reads.

## Tmux stand-ins

A test or driver that needs a program in place of tmux uses
[`test/tmux_standin.ml`](../test/tmux_standin.ml), an OCaml executable that
`LIBTMUX_STANDIN_*` environment variables configure: it replies with fixed text,
or runs the real tmux after adding `-f FILE`, recording its arguments or its
process ID. Link it under the name the program under test expects. A test
whose own Python file must act as tmux, such as `test/shutdown_test.py`, is
executable with a `python3` shebang. No `#!/bin/sh` shim stands in for tmux.

Start cost decides the language. On the maintainer's x86-64 WSL2 host with tmux
3.8, `hyperfine -N --warmup 3 --runs 30` measured one `-V` call as:

| Program | Mean per call |
| --- | --- |
| tmux alone | 0.93 ms |
| `sh` exec shim | 1.3 ms |
| OCaml stand-in | 1.7 ms |
| Python stand-in (`#!/usr/bin/env python3`) | 14.0 ms |
| Python stand-in (`uv run --script`) | 42.3 ms |

The CLI driver gives each command a 1 s deadline, and a command makes several
tmux calls. The OCaml stand-in adds under a millisecond to each; Python adds 13
ms or more.

## Exceptions

- `scripts/bench/concurrency.py` and `scripts/bench/mixed.py` start panes with
  `/bin/sh -c 'stty -echo; exec /bin/cat -u MARKER -'`. The pane must lose
  terminal echo before `cat` runs, tmux has no option for that, and `stty`
  cannot be chained to `cat` without a shell. The command runs inside the pane
  under test, not in place of tmux, so the start-cost measure above does not
  apply.
- `pyproject.toml` exempts the outer drivers listed there from `ANN`, and the
  drivers run as `python3 test/NAME.py` without a PEP 723 header, because they
  predate this policy. [#17](https://github.com/libtmux/libtmux-ocaml/issues/17)
  kept them as tests, not scripts. Annotating them and running them with
  `uv run` is open work in
  [#27](https://github.com/libtmux/libtmux-ocaml/issues/27). Annotate a driver
  when rewriting it and drop its `ANN` entry.
