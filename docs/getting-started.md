# Install and run your first capture

Follow the [source install](../README.md#install-from-source). You need opam,
tmux 3.3a or newer and a C compiler on Linux; the native clients build a small
C helper. Not on opam yet.

Activate the local switch in your shell, as the README shows, before changing to
a separate project. It leaves shell startup files and the default switch alone.

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
project.

```console
$ opam exec -- dune build
```

## Select an endpoint explicitly

`Endpoint.socket_path` accepts an absolute socket path; `Endpoint.named_socket`
describes tmux's `-L` name. Constructing either performs no I/O. Ordinary
`Client.connect` attaches to an existing daemon and does not start one.

The graph program takes the tmux binary and a socket path. It captures the
graph, closes its connection and prints what it captured. For a self-contained
run on a private server, see the
[README example](../README.md#read-a-real-tmux-graph).

The client and daemon must share a host, PID namespace and scratch filesystem;
a reachable socket alone does not prove that. A stale connection is an error,
and nothing reconnects a mutation for you.

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
