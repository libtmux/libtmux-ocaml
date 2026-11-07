# Captured fields

All fields below are acquired by the core snapshot schema on tmux 3.3+.
Text operations compare bytes without normalization or case folding.

| OCaml field | Value | tmux format |
| --- | --- | --- |
| `Session.Fields.id` | `string` | `session_id` |
| `Session.Fields.name` | `string` | `session_name` |
| `Session.Fields.attached` | `int` | `session_attached` |
| `Window.Fields.id` | `string` | `window_id` |
| `Window.Fields.name` | `string` | `window_name` |
| `Window.Fields.width` | `int` | `window_width` |
| `Window.Fields.height` | `int` | `window_height` |
| `Window.Fields.layout` | `string` | `window_layout` |
| `Window_link.Fields.index` | `int` | `window_index` |
| `Window_link.Fields.is_current` | `bool` | `window_active` |
| `Pane.Fields.id` | `string` | `pane_id` |
| `Pane.Fields.index` | `int` | `pane_index` |
| `Pane.Fields.active` | `bool` | `pane_active` |
| `Pane.Fields.dead` | `bool` | `pane_dead` |
| `Pane.Fields.title` | `string` | `pane_title` |
| `Pane.Fields.current_command` | `string` | `pane_current_command` |
| `Pane.Fields.current_path` | `string` | `pane_current_path` |
| `Pane.Fields.width` | `int` | `pane_width` |
| `Pane.Fields.height` | `int` | `pane_height` |
| `Pane.Fields.left` | `int` | `pane_left` |
| `Pane.Fields.top` | `int` | `pane_top` |
| `Client_observation.Fields.name` | `string` | `client_name` |
| `Client_observation.Fields.pid` | `int` | `client_pid` |
| `Client_observation.Fields.width` | `int` | `client_width` |
| `Client_observation.Fields.control_mode` | `bool` | `client_control_mode` |
