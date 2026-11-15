# Changelog

## Unreleased

- Add `libtmux-workspace`: validated workspace plans that apply from blocking
  and Eio clients. A failed apply removes only the panes it created and records
  the outcome for each one.
- Compensate a failed or interrupted apply pane by pane, in reverse creation
  order, so a pane another client moved into a new window survives. Breaking:
  remove `Execution.resource`; the `resource` field of `Execution.cleanup` is
  now `pane`, a `Libtmux.Pane.target`.
