# Changelog

## Unreleased

- Use `poll` for client and terminal readiness so descriptors above the
  `Unix.select` ceiling remain usable.
