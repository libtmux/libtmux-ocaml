# Format availability

Typed common fields are captured with the snapshot. `Formats.lookup` reads
those captured values without I/O. It distinguishes `Value`, `Missing`,
`Unacquired` and `Unsupported`; an empty captured string remains a value.

The catalog records upstream callbacks throughout tmux 3.3a–3.8.
Contexts are the callback's direct context dependencies, not a guarantee
that a value exists. Callers such as hooks and menus add other variables
outside this built-in catalog. The library does not silently acquire
uncaptured fields or infer absence from an empty format expansion.

| Format | Upstream kind | Contexts | Releases |
| --- | --- | --- | --- |
| `active_window_index` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `alternate_on` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `alternate_saved_x` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `alternate_saved_y` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `bracket_paste_flag` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `buffer_created` | Timestamp | Buffer | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `buffer_full` | Text | Buffer | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `buffer_mode_format` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `buffer_name` | Text | Buffer | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `buffer_sample` | Text | Buffer | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `buffer_size` | Text | Buffer | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_activity` | Timestamp | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_cell_height` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_cell_width` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_colours` | Text | Client | 3.8 |
| `client_control_mode` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_created` | Timestamp | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_discarded` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_flags` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_height` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_key_table` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_last_session` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_mode_format` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_name` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_pid` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_prefix` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_readonly` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_session` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_termfeatures` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_termname` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_termtype` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_theme` | Text | Client | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_tty` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_uid` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_user` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_utf8` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_width` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `client_written` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `config_files` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_blinking` | Text | Pane | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_character` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_colour` | Text | Pane | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_shape` | Text | Pane | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_very_visible` | Text | Pane | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_x` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `cursor_y` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `history_added` | Text | Pane | 3.8 |
| `history_all_bytes` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `history_bytes` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `history_collected` | Text | Pane | 3.8 |
| `history_generation` | Text | Pane | 3.8 |
| `history_limit` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `history_size` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `host` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `host_short` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `insert_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `keypad_cursor_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `keypad_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `last_window_index` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `loop_last_flag` | Text | Server | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c |
| `mouse_all_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_any_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_button_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_hyperlink` | Text | Mouse | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_line` | Text | Mouse | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_pane` | Text | Mouse | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_sgr_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_standard_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_status_line` | Text | Client, Mouse | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_status_range` | Text | Client, Mouse | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_utf8_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_word` | Text | Mouse | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_x` | Text | Client, Mouse | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `mouse_y` | Text | Client, Mouse | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `next_session_id` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `origin_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_active` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_at_bottom` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_at_left` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_at_right` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_at_top` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_bg` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_bottom` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_command_duration` | Text | Pane | 3.8 |
| `pane_command_end_time` | Timestamp | Pane | 3.8 |
| `pane_command_running` | Text | Pane | 3.8 |
| `pane_command_start_time` | Timestamp | Pane | 3.8 |
| `pane_command_status` | Text | Pane | 3.8 |
| `pane_current_command` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_current_path` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_dead` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_dead_signal` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_dead_status` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_dead_time` | Timestamp | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_fg` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_flags` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_floating_flag` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_format` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_height` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_id` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_in_mode` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_index` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_input_off` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_key_mode` | Text | Pane | 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_last` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_last_output_time` | Timestamp | Pane | 3.8 |
| `pane_last_prompt_time` | Timestamp | Pane | 3.8 |
| `pane_left` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_marked` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_marked_set` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_modal_flag` | Text | Pane | 3.8 |
| `pane_mode` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_output_generation` | Text | Pane | 3.8 |
| `pane_path` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_pb_progress` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_pb_state` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_pid` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_pipe` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_pipe_pid` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_private_modes` | Text | Pane | 3.8 |
| `pane_right` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_search_string` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_start_command` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_start_command_list` | Text | Pane | 3.8 |
| `pane_start_path` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_synchronized` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_tabs` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_title` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_top` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_tty` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_unseen_changes` | Text | Pane | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_unzoomed_height` | Text | Pane | 3.8 |
| `pane_unzoomed_width` | Text | Pane | 3.8 |
| `pane_width` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_x` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_y` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_z` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pane_zoomed_flag` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `pid` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `scroll_region_lower` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `scroll_region_upper` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `server_sessions` | Text | Server | 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_active` | Text | Client, Session | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_activity` | Timestamp | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_activity_flag` | Text | Session, Window_link | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c |
| `session_activity_flag` | Text | Session | 3.8 |
| `session_alert` | Text | Session | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_alerts` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_attached` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_attached_list` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_bell_flag` | Text | Session | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_created` | Timestamp | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_format` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_group` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_group_attached` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_group_attached_list` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_group_list` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_group_many_attached` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_group_size` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_grouped` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_id` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_last_attached` | Timestamp | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_many_attached` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_marked` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_name` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_path` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_silence_flag` | Text | Session, Window_link | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c |
| `session_silence_flag` | Text | Session | 3.8 |
| `session_stack` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `session_windows` | Text | Session | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `sixel_support` | Text | Server | 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `socket_path` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `start_time` | Timestamp | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `synchronized_output_flag` | Text | Pane | 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `tree_mode_format` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `uid` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `user` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `version` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_active` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_active_clients` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_active_clients_list` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_active_sessions` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_active_sessions_list` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_activity` | Timestamp | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_activity_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_bell_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_bigger` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_cell_height` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_cell_width` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_end_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_flags` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_format` | Text | Server | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_height` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_id` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_index` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_last_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_layout` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c |
| `window_layout` | Text | Connection, Window | 3.8 |
| `window_linked` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_linked_sessions` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_linked_sessions_list` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_manual_height` | Text | Window | 3.8 |
| `window_manual_width` | Text | Window | 3.8 |
| `window_marked_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_modal_pane` | Text | Window | 3.8 |
| `window_name` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_offset_x` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_offset_y` | Text | Client | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_panes` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_raw_flags` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_silence_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_stack_index` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_start_flag` | Text | Window_link | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_visible_layout` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c |
| `window_visible_layout` | Text | Connection, Window | 3.8 |
| `window_width` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `window_zoomed_flag` | Text | Window | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |
| `wrap_flag` | Text | Pane | 3.3a, 3.4, 3.5, 3.5a, 3.6, 3.6a, 3.6b, 3.7, 3.7a, 3.7b, 3.7c, 3.8 |

## Sources

- [tmux 3.3a format.c](https://github.com/tmux/tmux/blob/3.3a/format.c), SHA-256 `8e8a9e95a8b4720baa5587c9f5f6c3b0237d5587cda871ec3e94c815b2d933ae`.
- [tmux 3.4 format.c](https://github.com/tmux/tmux/blob/3.4/format.c), SHA-256 `eb22e23a6a9b2591b379a9c41315d7a748300d7bb103067d92394730a86cd200`.
- [tmux 3.5 format.c](https://github.com/tmux/tmux/blob/3.5/format.c), SHA-256 `6b01d94b90708cfee37cb49ee1a3c4fba654876b15a39744f91981d99fda3613`.
- [tmux 3.5a format.c](https://github.com/tmux/tmux/blob/3.5a/format.c), SHA-256 `6b01d94b90708cfee37cb49ee1a3c4fba654876b15a39744f91981d99fda3613`.
- [tmux 3.6 format.c](https://github.com/tmux/tmux/blob/3.6/format.c), SHA-256 `bf5d240f0a85eb4ca6907ebd06e47814843a0e436697375c088ed4301a876204`.
- [tmux 3.6a format.c](https://github.com/tmux/tmux/blob/3.6a/format.c), SHA-256 `6911f27ae9f27b005972809d9d87a6de43008c63c6e20c0eb39e131186387f5d`.
- [tmux 3.6b format.c](https://github.com/tmux/tmux/blob/3.6b/format.c), SHA-256 `6911f27ae9f27b005972809d9d87a6de43008c63c6e20c0eb39e131186387f5d`.
- [tmux 3.7 format.c](https://github.com/tmux/tmux/blob/3.7/format.c), SHA-256 `db223e9d2bf3ccbb704490069c8436caed0f4152ab760067d3b8a55e6575b180`.
- [tmux 3.7a format.c](https://github.com/tmux/tmux/blob/3.7a/format.c), SHA-256 `db223e9d2bf3ccbb704490069c8436caed0f4152ab760067d3b8a55e6575b180`.
- [tmux 3.7b format.c](https://github.com/tmux/tmux/blob/3.7b/format.c), SHA-256 `db223e9d2bf3ccbb704490069c8436caed0f4152ab760067d3b8a55e6575b180`.
- [tmux 3.7c format.c](https://github.com/tmux/tmux/blob/3.7c/format.c), SHA-256 `5c9c89b3291668c5df8eedb73c882833b79af3b9493a210c825e43454327b3ea`.
- [tmux 3.8 format.c](https://github.com/tmux/tmux/blob/3.8/format.c), SHA-256 `869d5a7c320eca66f9a50e6ff2e9266839a61eb11bcd0de4e1dfc4597a4c703d`.
