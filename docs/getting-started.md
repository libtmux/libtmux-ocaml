# Install and run your first capture

Use the [README installation](../README.md#install-from-source) with OCaml
5.5.2, opam and tmux on Linux. The native clients compile a small Linux C helper
and require a C compiler and system headers. This source checkout installs the
libraries; no registry release is available yet.

Activate the local switch in the current shell as shown in the README before
changing to a separate project. This exports the switch choice for `opam exec`
without changing shell startup files or the global default switch.

## Link an installed library

For a blocking program, use a Dune executable with `libtmux` and `libtmux-unix`:

```dune
(executable
 (name main)
 (libraries libtmux libtmux-unix))
```

For the Eio examples, link the Eio backend and the application's runtime entry
point instead:

```dune
(executable
 (name main)
 (libraries libtmux libtmux-eio eio_main))
```

Create `dune-project` with `(lang dune 3.24)`, save the
[graph program](../examples/native_graph.ml) as `main.ml`, and build from that
project. The installed-example check does this outside the repository with a
separate install prefix; it does not depend on source-tree library resolution.

```console
$ opam exec -- dune build
```

## Select an endpoint explicitly

`Endpoint.socket_path` accepts an absolute socket path; `Endpoint.named_socket`
describes tmux's `-L` name. Constructing either performs no I/O. Ordinary
`Client.connect` attaches to an existing daemon and does not start one.

The [private demo setup](../README.md#read-a-real-tmux-graph) creates an owned
socket and a `cat` pane. Run the graph program with the tmux binary and socket
path, or copy its complete source into your project. It captures the graph,
closes its connection and prints retained observations.

A connection identifies the daemon PID twice around pidfd acquisition. The
client and daemon must share a PID namespace and local scratch filesystem;
an accessible socket by itself does not establish those conditions. A stale
source is an error, never permission to reconnect a mutation automatically.

## Run a concurrent application

The [complete Eio example](../examples/native_watch.ml) calls `Eio_main.run`
and `Eio.Switch.run`, then supplies `process_mgr` and `mono_clock` from the
application environment. Use that outer shape in your application. Capturing
and querying values does not require adopting Eio in the pure core.

Expected failures return `result` and print with `Error.pp`. Backend
cancellation propagates separately. Clients and subscriptions belong to their
connecting domain; immutable observations can be shared. Close owned resources
with `Fun.protect` or the supplied Eio switch.

[Object graph](graph.md) · [Queries](queries.md) · [Control](control.md) ·
[API](api.md) · [Compatibility](compatibility.md)
