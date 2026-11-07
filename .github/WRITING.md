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
