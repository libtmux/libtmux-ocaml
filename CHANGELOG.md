# Changelog

## Unreleased

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
