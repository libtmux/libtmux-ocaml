# Changelog

## Unreleased

- Escalate owned-helper shutdown after a 200 ms cooperative grace while other
  fibers can run, including failed and cancelled connection setup.
