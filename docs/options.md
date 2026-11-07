# Option and hook catalog

Generated from pinned upstream option tables. Descriptors list exact
captured releases; other releases need catalog qualification.

Values retain tmux's scalar type and array indexes. User options have
explicit `@` names and text values.

| Name | Kind | Scopes | Releases |
| --- | --- | --- | --- |
| `activity-action` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-bind-key` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-capture-pane` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-copy-mode` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-display-message` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-display-panes` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-kill-pane` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-list-buffers` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-list-clients` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-list-keys` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-list-panes` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-list-sessions` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-list-windows` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-load-buffer` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-lock-server` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-new-session` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-new-window` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-paste-buffer` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-pipe-pane` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-queue` | Commands array | SESSION | 3.3, 3.3a, 3.4 |
| `after-refresh-client` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-rename-session` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-rename-window` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-resize-pane` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-resize-window` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-save-buffer` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-select-layout` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-select-pane` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-select-window` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-send-keys` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-set-buffer` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-set-environment` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-set-hook` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-set-option` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-show-environment` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-show-messages` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-show-options` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-split-window` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `after-swap-window` | Commands array | SESSION | 3.8 |
| `after-unbind-key` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `aggressive-resize` | Flag | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `alert-activity` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `alert-bell` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `alert-silence` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `allow-passthrough` | Flag | WINDOW, PANE | 3.3, 3.3a |
| `allow-passthrough` | Choice | WINDOW, PANE | 3.4, 3.8 |
| `allow-rename` | Flag | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `allow-set-title` | Flag | WINDOW, PANE | 3.8 |
| `alternate-screen` | Flag | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `assume-paste-time` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `automatic-rename` | Flag | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `automatic-rename-format` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `backspace` | Key | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `base-index` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `bell-action` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `buffer-limit` | Number | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `clear-on-attach` | Flag | SERVER | 3.8 |
| `client-active` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `client-attached` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `client-closed` | Commands array | SESSION | 3.8 |
| `client-created` | Commands array | SESSION | 3.8 |
| `client-dark-theme` | Commands array | SESSION | 3.8 |
| `client-detached` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `client-focus-in` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `client-focus-out` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `client-light-theme` | Commands array | SESSION | 3.8 |
| `client-resized` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `client-session-changed` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `clock-mode-colour` | Colour | WINDOW | 3.3, 3.3a, 3.4 |
| `clock-mode-colour` | Text | WINDOW | 3.8 |
| `clock-mode-style` | Choice | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `codepoint-widths` | Text array | SERVER | 3.8 |
| `command-alias` | Text array | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `command-error` | Commands array | SESSION | 3.8 |
| `copy-command` | Text | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `copy-mode-current-line-number-style` | Text | WINDOW | 3.8 |
| `copy-mode-current-line-style` | Text | WINDOW | 3.8 |
| `copy-mode-current-match-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `copy-mode-line-number-style` | Text | WINDOW | 3.8 |
| `copy-mode-line-numbers` | Choice | WINDOW | 3.8 |
| `copy-mode-mark-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `copy-mode-match-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `copy-mode-position-format` | Text | WINDOW, PANE | 3.8 |
| `copy-mode-position-style` | Text | WINDOW | 3.8 |
| `copy-mode-selection-style` | Text | WINDOW | 3.8 |
| `cursor-colour` | Colour | WINDOW, PANE | 3.3, 3.3a, 3.4 |
| `cursor-colour` | Text | WINDOW, PANE | 3.8 |
| `cursor-style` | Choice | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `dark-theme-black` | Text | SERVER | 3.8 |
| `dark-theme-blue` | Text | SERVER | 3.8 |
| `dark-theme-cyan` | Text | SERVER | 3.8 |
| `dark-theme-dark-grey` | Text | SERVER | 3.8 |
| `dark-theme-green` | Text | SERVER | 3.8 |
| `dark-theme-light-grey` | Text | SERVER | 3.8 |
| `dark-theme-magenta` | Text | SERVER | 3.8 |
| `dark-theme-red` | Text | SERVER | 3.8 |
| `dark-theme-white` | Text | SERVER | 3.8 |
| `dark-theme-yellow` | Text | SERVER | 3.8 |
| `default-client-command` | Commands | SERVER | 3.8 |
| `default-command` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `default-shell` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `default-size` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `default-terminal` | Text | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `destroy-unattached` | Flag | SESSION | 3.3, 3.3a |
| `destroy-unattached` | Choice | SESSION | 3.4, 3.8 |
| `detach-on-destroy` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `display-panes-active-colour` | Colour | SESSION | 3.3, 3.3a, 3.4 |
| `display-panes-active-colour` | Text | WINDOW | 3.8 |
| `display-panes-border-style` | Text | WINDOW | 3.8 |
| `display-panes-colour` | Colour | SESSION | 3.3, 3.3a, 3.4 |
| `display-panes-colour` | Text | WINDOW | 3.8 |
| `display-panes-format` | Text | WINDOW | 3.8 |
| `display-panes-time` | Number | SESSION | 3.3, 3.3a, 3.4 |
| `display-panes-time` | Number | WINDOW | 3.8 |
| `display-time` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `editor` | Text | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `escape-time` | Number | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `exit-empty` | Flag | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `exit-unattached` | Flag | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `extended-keys` | Choice | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `extended-keys-format` | Choice | SERVER | 3.8 |
| `fill-character` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `focus-events` | Flag | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `focus-follows-mouse` | Flag | SESSION | 3.8 |
| `get-clipboard` | Choice | SERVER | 3.8 |
| `history-file` | Text | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `history-limit` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `initial-repeat-time` | Number | SESSION | 3.8 |
| `input-buffer-size` | Number | SERVER | 3.8 |
| `key-table` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `light-theme-black` | Text | SERVER | 3.8 |
| `light-theme-blue` | Text | SERVER | 3.8 |
| `light-theme-cyan` | Text | SERVER | 3.8 |
| `light-theme-dark-grey` | Text | SERVER | 3.8 |
| `light-theme-green` | Text | SERVER | 3.8 |
| `light-theme-light-grey` | Text | SERVER | 3.8 |
| `light-theme-magenta` | Text | SERVER | 3.8 |
| `light-theme-red` | Text | SERVER | 3.8 |
| `light-theme-white` | Text | SERVER | 3.8 |
| `light-theme-yellow` | Text | SERVER | 3.8 |
| `lock-after-time` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `lock-command` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `main-pane-height` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `main-pane-width` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `marked-pane-changed` | Commands array | SESSION | 3.8 |
| `menu-border-lines` | Choice | WINDOW | 3.4, 3.8 |
| `menu-border-style` | Text | WINDOW | 3.4, 3.8 |
| `menu-selected-style` | Text | WINDOW | 3.4, 3.8 |
| `menu-style` | Text | WINDOW | 3.4, 3.8 |
| `message-command-style` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `message-format` | Text | SESSION | 3.8 |
| `message-limit` | Number | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `message-line` | Choice | SESSION | 3.4, 3.8 |
| `message-style` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `mode-keys` | Choice | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `mode-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `monitor-activity` | Flag | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `monitor-bell` | Flag | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `monitor-silence` | Number | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `mouse` | Flag | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `other-pane-height` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `other-pane-width` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `pane-active-border-style` | Text | WINDOW | 3.3, 3.3a, 3.4 |
| `pane-active-border-style` | Text | WINDOW, PANE | 3.8 |
| `pane-activity` | Commands array | WINDOW, PANE | 3.8 |
| `pane-base-index` | Number | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `pane-bell` | Commands array | WINDOW, PANE | 3.8 |
| `pane-border-format` | Text | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-border-indicators` | Choice | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `pane-border-lines` | Choice | WINDOW | 3.3, 3.3a, 3.4 |
| `pane-border-lines` | Choice | WINDOW, PANE | 3.8 |
| `pane-border-status` | Choice | WINDOW | 3.3, 3.3a, 3.4 |
| `pane-border-status` | Choice | WINDOW, PANE | 3.8 |
| `pane-border-style` | Text | WINDOW | 3.3, 3.3a, 3.4 |
| `pane-border-style` | Text | WINDOW, PANE | 3.8 |
| `pane-colours` | Colour array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-command-finished` | Commands array | WINDOW, PANE | 3.8 |
| `pane-command-started` | Commands array | WINDOW, PANE | 3.8 |
| `pane-created` | Commands array | WINDOW, PANE | 3.8 |
| `pane-died` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-exited` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-focus-in` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-focus-out` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-mode-changed` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-mode-entered` | Commands array | WINDOW, PANE | 3.8 |
| `pane-mode-exited` | Commands array | WINDOW, PANE | 3.8 |
| `pane-moved` | Commands array | WINDOW, PANE | 3.8 |
| `pane-prompt-closed` | Commands array | WINDOW, PANE | 3.8 |
| `pane-prompt-opened` | Commands array | WINDOW, PANE | 3.8 |
| `pane-resized` | Commands array | WINDOW, PANE | 3.8 |
| `pane-scrollbars` | Choice | WINDOW | 3.8 |
| `pane-scrollbars-position` | Choice | WINDOW | 3.8 |
| `pane-scrollbars-style` | Text | WINDOW, PANE | 3.8 |
| `pane-scrollbars-timeout` | Number | WINDOW | 3.8 |
| `pane-set-clipboard` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `pane-shell-prompt` | Commands array | WINDOW, PANE | 3.8 |
| `pane-status-current-style` | Text | WINDOW | 3.8 |
| `pane-status-style` | Text | WINDOW | 3.8 |
| `pane-title-changed` | Commands array | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `popup-border-lines` | Choice | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `popup-border-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `popup-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `prefix` | Key | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `prefix-timeout` | Number | SERVER | 3.8 |
| `prefix2` | Key | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `prompt-command-cursor-colour` | Text | SESSION | 3.8 |
| `prompt-command-cursor-style` | Choice | SESSION | 3.8 |
| `prompt-cursor-colour` | Text | SESSION | 3.8 |
| `prompt-cursor-style` | Choice | SESSION | 3.8 |
| `prompt-history-limit` | Number | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `remain-on-exit` | Choice | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `remain-on-exit-format` | Text | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `renumber-windows` | Flag | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `repeat-time` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `scroll-on-clear` | Flag | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `session-added-to-group` | Commands array | SESSION | 3.8 |
| `session-closed` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `session-created` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `session-removed-from-group` | Commands array | SESSION | 3.8 |
| `session-renamed` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `session-status-current-style` | Text | WINDOW | 3.8 |
| `session-status-style` | Text | WINDOW | 3.8 |
| `session-window-changed` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `set-clipboard` | Choice | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `set-titles` | Flag | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `set-titles-string` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `silence-action` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-bg` | Colour | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-fg` | Colour | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-format` | Text array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-interval` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-justify` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-keys` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-left` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-left-length` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-left-style` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-position` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-right` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-right-length` | Number | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-right-style` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `status-style` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `switch-mode-match-style` | Text | WINDOW, PANE | 3.8 |
| `synchronize-panes` | Flag | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `terminal-features` | Text array | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `terminal-overrides` | Text array | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `theme` | Choice | SERVER | 3.8 |
| `tiled-layout-max-columns` | Number | WINDOW | 3.8 |
| `tree-mode-border-style` | Text | WINDOW | 3.8 |
| `tree-mode-preview-format` | Text | WINDOW, PANE | 3.8 |
| `tree-mode-preview-style` | Text | WINDOW | 3.8 |
| `tree-mode-selection-style` | Text | WINDOW | 3.8 |
| `update-environment` | Text array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `user-keys` | Text array | SERVER | 3.3, 3.3a, 3.4, 3.8 |
| `variation-selector-always-wide` | Flag | SERVER | 3.8 |
| `visual-activity` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `visual-bell` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `visual-silence` | Choice | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `window-active-style` | Text | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `window-closed` | Commands array | WINDOW | 3.8 |
| `window-created` | Commands array | WINDOW | 3.8 |
| `window-layout-changed` | Commands array | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-linked` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `window-pane-changed` | Commands array | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-pane-current-status-format` | Text | WINDOW | 3.8 |
| `window-pane-status-format` | Text | WINDOW | 3.8 |
| `window-renamed` | Commands array | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-resized` | Commands array | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-size` | Choice | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-activity-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-bell-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-current-format` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-current-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-format` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-last-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-separator` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-status-style` | Text | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `window-style` | Text | WINDOW, PANE | 3.3, 3.3a, 3.4, 3.8 |
| `window-unlinked` | Commands array | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `window-unzoomed` | Commands array | WINDOW | 3.8 |
| `window-zoomed` | Commands array | WINDOW | 3.8 |
| `word-separators` | Text | SESSION | 3.3, 3.3a, 3.4, 3.8 |
| `wrap-search` | Flag | WINDOW | 3.3, 3.3a, 3.4, 3.8 |
| `xterm-keys` | Flag | WINDOW | 3.3, 3.3a, 3.4, 3.8 |

## Sources

- [tmux 3.3 options-table.c](https://github.com/tmux/tmux/blob/3.3/options-table.c), SHA-256 `dbf0432e6620735554e798a0aef55c5dd2a1021518261fef4b3f93e60989d2b4`.
- [tmux 3.3a options-table.c](https://github.com/tmux/tmux/blob/3.3a/options-table.c), SHA-256 `dbf0432e6620735554e798a0aef55c5dd2a1021518261fef4b3f93e60989d2b4`.
- [tmux 3.4 options-table.c](https://github.com/tmux/tmux/blob/3.4/options-table.c), SHA-256 `b50f5da4d81dfd26089d35510b96f8f1cf5457d05835d8494feeea0c5cf4e1ea`.
- [tmux 3.8 options-table.c](https://github.com/tmux/tmux/blob/3.8/options-table.c), SHA-256 `cbf3b034785b30aeee3d67032f99e9d9b173a321e11b19be1a11c9e9914fc866`.
