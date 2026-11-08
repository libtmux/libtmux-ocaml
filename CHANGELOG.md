# Changelog

## Unreleased

- Wait for shared teardown completion when Eio callers close a client
  concurrently.
- Retain process cleanup diagnostics across failed setup, cancellation and
  closure without replacing the original exception.
- Escalate owned-helper shutdown from TERM to KILL after a 200 ms cooperative
  grace and reap the child in blocking and Eio clients.
- Support high-numbered file descriptors in the blocking client and terminal
  attachment, including cancellation and readiness deadlines.
