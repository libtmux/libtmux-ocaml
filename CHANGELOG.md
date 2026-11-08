# Changelog

## Unreleased

- Escalate owned-helper shutdown from TERM to KILL after a 200 ms cooperative
  grace and reap the child in blocking and Eio clients.
- Support high-numbered file descriptors in the blocking client and terminal
  attachment, including cancellation and readiness deadlines.
