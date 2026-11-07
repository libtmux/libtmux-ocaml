# Native operations

`Libtmux.Operations` constructs commands without I/O. Both native clients
provide the conveniences below; each submits and awaits that command.
Use `submit` and `await` separately to retain an operation handle across
cancellation. Blocking conveniences accept an optional cancellation token.

| Operation | Native command result |
| --- | --- |
| `capture` | `Snapshot.t` |
| `capture_text` | `Captured_text.t` |
| `rename_window` | `unit` |
| `rename_session` | `unit` |
| `switch_client_at` | `unit` |
| `request_detach_client_at` | `unit` |
| `refresh_client_at` | `unit` |
| `resize_control_client_at` | `unit` |
| `send_text` | `unit` |
| `send_keys` | `unit` |
| `wait_for` | `unit` |
| `signal` | `unit` |
| `capture_environment` | `Environment.t` |
| `set_environment` | `unit` |
| `unset_environment` | `unit` |
| `remove_environment` | `unit` |
| `capture_options` | `Options.t` |
| `read_option` | `Options.value option` |
| `set_option` | `unit` |
| `unset_option` | `unit` |
| `clear_option_array` | `unit` |
| `capture_hooks` | `Options.t` |
| `read_hook` | `Options.value option` |
| `set_hook` | `unit` |
| `remove_hook` | `unit` |
| `run_hook` | `unit` |
| `create_session` | `Created.t` |
| `create_window` | `Created.t` |
| `split_pane` | `Created.t` |
| `break_pane` | `Created.t` |
| `kill_session` | `unit` |
| `kill_window` | `unit` |
| `kill_pane` | `unit` |
| `select_window_at` | `unit` |
| `unlink_window_at` | `unit` |
| `link_window` | `unit` |
| `move_window_at` | `unit` |
| `select_pane` | `unit` |
| `set_pane_title` | `unit` |
| `resize_pane` | `unit` |
| `resize_window` | `unit` |
| `select_layout` | `unit` |
| `cycle_layout` | `unit` |
| `move_pane` | `unit` |
| `swap_panes` | `unit` |
| `rotate_panes` | `unit` |
| `zoom_pane` | `unit` |
| `respawn_pane` | `unit` |
| `clear_history` | `unit` |
