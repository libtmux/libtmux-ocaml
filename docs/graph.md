# Sessions, window links and panes

A snapshot contains sessions, global windows, session-specific window links,
panes and captured clients. Entity values are abstract immutable observations.
They remain readable after their client closes.

```text
Session ── Window_link ── Window ── Pane
                index       │
                   another link can share this window
```

- A window can be linked to several sessions, or twice in one session.
  `Session.window_links` keeps each link and index; `Session.windows` returns
  distinct windows in first-link order.
- `Window.panes` holds that window's captured panes. Local traversal does no
  I/O, lazy refresh or per-object subprocess calls.
- Captured client rows and attached-client counts include the library's own
  control connection when present.

The [graph program](../examples/showcase_graph.ml) creates a second session and
links the first window into it at index 7. It runs on a private server it
starts and removes:

```console
$ opam exec -- dune exec examples/showcase_graph.exe -- tmux
```

```text
socket=/tmp/libtmux-ocaml-showcase-0cd3a1/server
linked/0 linked-home: 1 pane(s)
linked/7 editor: 1 pane(s)
showcase/0 editor: 1 pane(s)
graph: 2 sessions, 2 windows, 3 links, 2 panes
```

The `editor` window appears under both sessions, at each link's own index.

- **Identity.** An ID is scoped to a connection source. `same_entity` needs the
  same source generation and entity ID, so separate connections compare unequal
  even on one daemon. `same_observation` also tells captures apart. Use them or
  `Id.equal`, not polymorphic equality.
- **Currency.** A valid target does not make captured names, geometry or
  membership current. A link context is an observed session/index/window tuple,
  not a stable link across unlinking or reindexing.
- **Capture.** It spans an interval and is not an atomic transaction. A
  disappearing or conflicting object is a capture error, never an empty
  relationship.
- **Retention.** Each entity retains its whole snapshot, so keeping one pane
  from every refresh keeps every capture; keep scalar summaries instead.
  `Pane.target` omits the graph but stays bound to its connection generation.
  See the [retained-heap measurements](benchmarking.md#heap-retained-across-captures).

[Queries](queries.md) · [Recovery](control.md) · [API](api.md)
