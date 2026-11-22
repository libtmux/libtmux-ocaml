# Changelog

## Unreleased

- Add `Endpoint.from_env` to resolve `LIBTMUX_SOCKET_PATH`, `LIBTMUX_SOCKET`,
  `TMUX` and tmux's `default` socket without starting a daemon.
- Add the core `libtmux` package: snapshots and queries over sessions, windows
  and panes, typed commands, and option and format catalogs for tmux 3.3a
  through 3.8.
- Add `Command.Kill_server` and `Operations.kill_server`, a command without a
  reply that stops the whole tmux server.
