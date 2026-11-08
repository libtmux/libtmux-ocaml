# Changelog

## Unreleased

- Reap stopped and TERM-resistant client helpers after a 200 ms shutdown grace,
  including failed connection setup and terminal cancellation.
- Use `poll` for client and terminal readiness so descriptors above the
  `Unix.select` ceiling remain usable.
