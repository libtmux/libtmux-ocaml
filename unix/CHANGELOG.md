# Changelog

## Unreleased

- Pause observed panes before releasing a stream lane so tmux 3.2 through 3.8
  do not abort when a subscription closes while its pane is still printing.
- Preserve rendered-wait errors and cancellation when subscription cleanup
  fails; report cleanup failure before success or renewed coverage.
- Retain connection and subscription cleanup results; overlapping Eio closes
  wait for the same helper cleanup instead of returning before reaping.
- Reject process I/O after closure and retain helper cleanup failures on
  repeated stops.
- Add caller-owned cleanup reports and preserve primary failures while
  attempting independent resource releases.
- Reap stopped and TERM-resistant client helpers after a 200 ms shutdown grace,
  including failed connection setup and terminal cancellation.
- Use `poll` for client and terminal readiness so descriptors above the
  `Unix.select` ceiling remain usable.
