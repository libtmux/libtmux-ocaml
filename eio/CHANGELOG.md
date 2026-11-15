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
- Add `Client.kill_server`: stop the daemon the client is bound to, report
  success when that daemon exits, and close the client.
- Add `with_private_daemon`: run a function against a foreground tmux daemon in
  its own `0700` directory, with an optional config file and an optional first
  session. It stops and reaps the daemon, checks that nothing answers and
  removes the directory on every exit, including Eio cancellation. It keeps the
  directory when the daemon still answers.
- Add `?config_file` to `Workspace.submit_bootstrap`, passed to tmux as `-f`
  when the new-session command starts the server.
- Add `Workspace`: apply a workspace plan through an existing client, or
  bootstrap a missing endpoint with `Workspace.submit_bootstrap` and bind the
  same connection. A handle retains its journal after cancellation and close.
