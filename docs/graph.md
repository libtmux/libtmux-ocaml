# Sessions, window links and panes

A snapshot contains sessions, global windows, session-specific window links,
panes and captured clients. Entity values are abstract immutable observations.
They remain readable after their client closes.

```text
Session ── Window_link ── Window ── Pane
                index       │
                   another link can share this window
```

A window can be linked to multiple sessions, or linked more than once within
one session. `Session.window_links` retains each context and index.
`Session.windows` returns distinct global windows in first-link order.
`Window.panes` contains that global window's captured panes. Local traversal
performs no I/O, lazy refresh or per-object subprocess calls.

The [graph program](../examples/native_graph.ml) deliberately walks links. To
see the same window in two sessions, run the [README setup](../README.md#read-a-real-tmux-graph),
then create another session:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/server" \
    new-session \
    -d \
    -s linked \
    -- "exec cat"
```

Link the demo's window at index 7 in the other session:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/server" \
    link-window \
    -d \
    -s @0 \
    -t linked:7
```

```console
$ opam exec -- dune exec examples/native_graph.exe -- \
    tmux "$LIBTMUX_DEMO_DIR/server"
```

The same window ID and pane ID appear under both sessions, at their respective
link indexes. The installed-example check asserts both appearances. Remove
only the additional session when finished:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_DEMO_DIR/server" \
    kill-session -t '=linked'
```

An entity ID is scoped to a connection source. `same_entity` compares that
identity; `same_observation` also distinguishes captures. Use those operations
or explicit `Id.equal`, rather than polymorphic equality over observations.
A link context is an observed session/index/window tuple, not a stable link
incarnation across unlinking or reindexing.

Capture provenance records an acquisition interval. Several tmux commands do
not form an atomic server transaction. Disappearing or conflicting objects
produce a capture error rather than a fabricated empty relationship.

[Queries](queries.md) · [Recovery](control.md) · [API](api.md)
