# Changelog

## Unreleased

- Share cleanup reports with the blocking backend and preserve native
  cancellation when secondary resource cleanup fails.
- Escalate owned-helper shutdown after a 200 ms cooperative grace while other
  fibers can run, including failed and cancelled connection setup.
