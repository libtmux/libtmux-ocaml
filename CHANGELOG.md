# Changelog

## Unreleased

## 0.0.1

- Publish the native graph and query model, blocking Linux and Eio clients,
  optional JSON support, workspace libraries and `tmux-workspace` command.
- Target OCaml 5.5.2 and tmux 3.3a through 3.8. See the
  [current limits](docs/status.md) before adopting the native clients.
- Pause observed panes before releasing a stream lane so tmux 3.2 through 3.8
  do not abort when a subscription closes while its pane is still printing.
- Preserve rendered-wait errors and cancellation when subscription cleanup
  fails; report cleanup failure before success or renewed coverage.
- Retain connection and subscription cleanup results; overlapping Eio closes
  wait for the same helper cleanup instead of returning before reaping.
- Reject new Eio command and subscription admission as soon as client close
  starts, before waiting for stream helpers to exit.
- Reject resumed process I/O after close, including when descriptor numbers
  have been reused. Retain helper-stop results across repeated cleanup.
- Wait for shared teardown completion when Eio callers close a client
  concurrently.
- Retain process cleanup diagnostics across failed setup, cancellation and
  closure without replacing the original exception.
- Escalate owned-helper shutdown from TERM to KILL after a 200 ms cooperative
  grace and reap the child in blocking and Eio clients.
- Support high-numbered file descriptors in the blocking client and terminal
  attachment, including cancellation and readiness deadlines.
