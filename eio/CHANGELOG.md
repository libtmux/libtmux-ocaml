# Changelog

## Unreleased

- Preserve rendered-wait errors and cancellation when subscription cleanup
  fails; report cleanup failure before success or renewed coverage.
- Retain connection and subscription cleanup results; overlapping Eio closes
  wait for the same helper cleanup instead of returning before reaping.
- Reject new Eio command and subscription admission as soon as client close
  starts, before waiting for stream helpers to exit.
- Own transferred control pipes explicitly and join readiness waiters before
  closing their descriptors. Switch release shares the same helper cleanup.
- Keep process reapers alive during cancellation and switch release, avoiding
  a shutdown deadlock with Eio's POSIX backend on Linux.
- Make concurrent client closes await the same teardown result and retain an
  earlier teardown failure on later calls.
- Share cleanup reports with the blocking backend and preserve native
  cancellation when secondary resource cleanup fails.
- Escalate owned-helper shutdown after a 200 ms cooperative grace while other
  fibers can run, including failed and cancelled connection setup.
