# Writing

This guide governs documentation, comments, commits, and review prose.
[CONTRIBUTING.md](CONTRIBUTING.md) governs development workflow.

## Voice

Lead with the conclusion or observable behavior, then support it with evidence.
Use active voice, concrete nouns, and short sentences. Assume no shared history:
explain the meaning of an issue or decision instead of giving only its ID.

Remove filler, promotional claims, emoji, and agent attribution. Distinguish
planned, implemented, tested, and published behavior. Answer questions before
editing. When responding to feedback, say whether you agree or disagree before
describing changes.

Document existing interfaces. Describe inputs, outputs, ownership, I/O, and
errors where relevant. Comments should explain an invariant or constraint that
the code does not make obvious; omit narration and duplicated information.

## README and task guides

Use the title **libtmux for OCaml**. Lead with the reader's task, installation,
the smallest complete working program, its result, and operational limits.
Keep one source-install route until a registry release has been verified.
Support and performance claims refer to the exact checked source and workload.
Do not infer a release policy from another port's warning text.

Keep API contracts beside their declarations and link to the guide that owns
each concept. A task guide shows the common call before variations and failures.
Explain completion, uncertainty, ownership and cleanup where they affect use.
Keep development history and validation diaries out of product guides.

## Executable examples

Edit source examples first. Derive snippets or check their exact source regions;
compile and execute the complete programs through installed public packages.
Run the displayed setup and commands, assert output and errors, and check owned
teardown. Imports, entry points and required inputs belong in the shown setup.
Do not supply a hidden prelude or claim a function declaration runs by itself.

A core capability showcase needs its own complete program, normally under 150
lines, with explicit server setup and no repository-only helper. CI must execute
its entry point and fail on a nonzero exit or a missing expected result. Record
the source, command, workflow/job and tmux floor. Show only implemented and
qualified capabilities; sending a command is not a run-to-exit API.

Clear inherited tmux context in test runners. Cleanup removes only resources the
example created. A borrowed server, pane or linked window does not become owned
because a new client or child was created beside it.

## OCaml API documentation

Document public modules and declarations in their `.mli` interfaces using native
odoc comments. The first sentence states a caller-visible result and stands on
its own. Use `[code]` for code and `{!Identifier}` for resolvable API links;
verify links and module introductions in the rendered reference.

Link the first meaningful mention of a related public type or operation. Use
odoc's typed references when a type and value share a name, and retain custom
link labels. Keep code literals distinct from references. Link module
introductions to their owning guides with odoc URL links. Cross-package
references must resolve with the documented build inputs; an optional backend
must not become a core runtime dependency to make a documentation link work.
Check both native odoc and shared-site HTML, including their destination anchors.

State whether an operation performs I/O, what a result means, and relevant
defaults, bounds, ordering, multiplicity, ownership and failure behavior.
Describe cancellation and admission separately from completion. Use MDX for
executable pure examples and installed real-tmux programs for effectful tasks.
Generated declarations inherit their source contract; edit the source interface
and regenerate rather than hand-editing backend copies.

## Markdown

Use CommonMark with a blank line before lists and after headings. Wrap prose
at 80 columns where practical. Avoid personal information and machine-specific
paths; use repository-relative links.

Code blocks are paste-and-run units:

- Put one command in each block; an explicit continuation or chain counts as
  one command.
- Put explanations outside the block.
- Mark shell commands as `console` and prefix them with `$ `.
- Split long commands with `\`, with one flag per continuation line.
- Use the appropriate language tag for source examples.

## Commits

Use `scope(type[detail]) Concise description` for the subject. Keep scopes
lowercase unless they name a class or proper product. Use imperative wording.

Follow the subject with a blank line, a `why:` paragraph explaining necessity
or impact, then `what:` and a short list of concrete changes. Focus each commit
on one topic. Keep temporary validation results in the review discussion.

Common types include `feat`, `fix`, `refactor`, `docs`, `chore`, and `test`.
Omit emoji and attribution trailers.

## Reviews and releases

Describe the final change for a reader who has not seen the conversation.
Report evidence and limits; avoid unsupported claims such as "robust" or
"optimized". Explain incompatible behavior and migration steps when relevant.

When changelogs or releases exist, describe changes that affect callers. Do not
invent release versions, dates, installation instructions, or API examples.
