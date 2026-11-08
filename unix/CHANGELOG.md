# Changelog

## Unreleased

- Add caller-owned cleanup reports and preserve primary failures while
  attempting independent resource releases.
- Reap stopped and TERM-resistant client helpers after a 200 ms shutdown grace,
  including failed connection setup and terminal cancellation.
- Use `poll` for client and terminal readiness so descriptors above the
  `Unix.select` ceiling remain usable.
