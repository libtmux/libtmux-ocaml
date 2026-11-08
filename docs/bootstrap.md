# Start a private tmux server from OCaml

Use `Workspace.submit_bootstrap` when the endpoint is known to be missing.
It creates the first session and binds a client through the same control
connection. The native workspace builder needs no JSON package;
`Workspace.await` performs startup.

For an existing daemon, use `Client.connect`, capture its graph, and create a
session through that client. See [control and recovery](control.md).

## Run the complete program

Complete the [source installation](getting-started.md), then run from the
checkout:

```console
$ opam exec -- dune exec examples/showcase_bootstrap.exe -- tmux
```

The program prints its temporary socket path followed by
`bootstrapped: 1 session, 1 window, 1 pane`. It creates a `bootstrap-demo` session
whose `editor` window runs `/bin/cat -u`, captures the graph, and reads that
snapshot after closing its client.

The [complete source](../examples/showcase_bootstrap.ml) includes its private
directory, tmux configuration, local version discovery and cleanup. To use the
whole program outside this checkout, save it as `main.ml` in the Dune project
from [first use](getting-started.md#link-an-installed-library) with:

```dune
(executable
 (name main)
 (libraries libtmux libtmux-workspace libtmux-unix unix))
```

CI compiles that complete file against installed packages and checks its exact
outcome line, graph assertions, directory cleanup and owned process exit on
tmux 3.3a and 3.8. The [executed inventory](../examples/showcase.json) records
its command and workflow.

## Build, plan, await and capture

The central function receives the binary's discovered version and a new private
socket path. `Config.make`, `Plan.make` and submission perform no I/O; the
function returns a retained execution handle:

<!-- example: examples/showcase_bootstrap.ml#bootstrap -->

```ocaml
let bootstrap ~binary ~version ~directory endpoint =
  let spawn = Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] }) in
  let config =
    Config.make ~directory ~session:"bootstrap-demo"
      [ Config.window ~name:"editor" [ Config.pane ~spawn () ] ]
    |> checked Config.pp_error
  in
  let plan =
    Plan.make ~endpoint ~version ~observed:None config |> checked Plan.pp_error
  in
  get (Workspace.submit_bootstrap ~binary plan)
```

`observed:None` means the endpoint is known to be missing. The full program
uses a newly created private directory to establish that precondition. Passing
`None` after a failed capture would discard the failure and produce the wrong
plan. A plan remains advisory; another process can still change the endpoint
before execution.

Keep that handle outside the cleanup scope. Await it, check the receipt, then
borrow its client for the capture:

<!-- example: examples/showcase_bootstrap.ml#await-bootstrap -->

```ocaml
let snapshot =
  protect
    ~finally:(fun () -> get (Workspace.close execution))
    (fun () ->
      let receipt = get (Workspace.await execution) in
      require_success receipt;
      let client = Option.get (Workspace.client execution) in
      get (Client.capture client))
```

`require_success` reports failed steps and compensation before raising. The
`protect` helper keeps that primary exception if closing also fails, reporting
the cleanup failure separately. Both helpers are in the complete source.
`Workspace.inspect execution` reads the retained journal after closure; inspect
reported creations and uncertainty before choosing another action. The
program stops without retrying. The
[workspace guide](workspaces.md#collisions-and-recovery) explains those receipts.

`Workspace.client` borrows the bootstrapped client. Close the workspace handle
after using that client; its snapshot stays readable.

## Choose the daemon's lifetime

Bootstrapping owns the new client, not the tmux daemon. Closing the handle
releases that client. The example explicitly configures its private daemon
with `exit-unattached on`, supplied through a small shell exec wrapper. The
daemon and its demonstration pane exit after
the final client detaches. It then removes only its own temporary files.

For an application that keeps the server, choose its normal tmux lifetime
policy and retain the workspace handle while using the borrowed client. An
existing or newly visible daemon does not become owned merely because this
application connected to it. Cancellation and a partial bootstrap can leave
effects; use [retained operation recovery](recovery.md) and the workspace
receipt rather than assuming closure undoes them.

[Object graph](graph.md) · [Workspaces](workspaces.md) · [Guide](README.md)
