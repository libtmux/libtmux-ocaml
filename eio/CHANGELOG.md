# Changelog

## Unreleased

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
