# Changelog

## Unreleased

- Add `--socket-name` and default server selection (`LIBTMUX_SOCKET_PATH`, else
  `LIBTMUX_SOCKET`, else `TMUX`, else `default`) when neither `--socket` nor
  `--socket-name` is supplied to `plan` or `apply`.
- Add `libtmux-workspace-cli`: an installed command that checks, previews and
  applies JSON workspace files and reports partial failures and interruptions.
