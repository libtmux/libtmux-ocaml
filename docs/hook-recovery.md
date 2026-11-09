# Inspect a creation after its hook fails

A failing `after-new-window` hook can leave the new window present while
`Libtmux_unix.Client.await` reports an unknown outcome. Retain the operation
handle before awaiting. `Libtmux_unix.Operation.inspect` keeps the IDs reported
before that failure, including after the client closes.

This example creates one window on an explicitly selected session, closes its
client, then prints the retained outcome and any reported window and pane IDs.
The setup installs a failing hook on a private demonstration daemon.

## Run the complete program

Complete the [source installation](getting-started.md), then run from the
checkout. Create a private directory:

```console
$ export LIBTMUX_HOOK_RECOVERY_DIR="$(mktemp -d -t libtmux-ocaml-hook-recovery.XXXXXX)"
```

Start the seed session:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_HOOK_RECOVERY_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s hook-demo \
    -- "exec /bin/cat -u"
```

Make the creation hook select a pane that does not exist:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_HOOK_RECOVERY_DIR/server" \
    set-hook \
    -g \
    after-new-window \
    "select-pane -t %4294967294"
```

The fresh daemon's seed session has ID `$0`. Quote that ID:

```console
$ opam exec -- dune exec examples/native_hook_recovery.exe -- \
    tmux "$LIBTMUX_HOOK_RECOVERY_DIR/server" '$0'
```

The program prints `operation=unknown`, a hook-failure cause,
`reported-window=@1; reported-pane=%1`, and `cleanup-issues=0; omitted=0`.
It submits one creation. Its retained handle stays outside the client cleanup
scope, so reporting runs after the close attempt, including when awaiting or
closing raises.

Inspect the current windows through a fresh command:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_HOOK_RECOVERY_DIR/server" \
    list-windows \
    -t '=hook-demo' \
    -F '#{window_id}:#{window_index}:#{window_name}:#{window_panes}'
```

The created window appears as `@1:4:hook-created:1`. The failed hook did not
undo its creation or stop its pane program.

Remove the private demonstration session, including that window:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_HOOK_RECOVERY_DIR/server" \
    kill-session \
    -t '=hook-demo'
```

```console
$ rm -f -- "$LIBTMUX_HOOK_RECOVERY_DIR/server"
```

```console
$ rmdir "$LIBTMUX_HOOK_RECOVERY_DIR"
```

## Retain evidence outside cleanup

The [complete source](../examples/native_hook_recovery.ml) uses installed
public libraries. A caller-owned cleanup report exists before connecting;
the operation handle remains accessible after closing. The local cleanup
helper preserves a primary exception while reporting secondary failures.

<!-- example: examples/native_hook_recovery.ml -->

```ocaml
open Libtmux
module Client = Libtmux_unix.Client
module Operation = Libtmux_unix.Operation
module Cleanup = Libtmux_unix.Cleanup

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let protect ~finally use =
  match use () with
  | value ->
      finally ();
      value
  | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      (try finally ()
       with cleanup ->
         Format.eprintf "cleanup failed: %s@." (Printexc.to_string cleanup));
      Printexc.raise_with_backtrace error backtrace

let report_created (created : Created.t) =
  Printf.printf "reported-window=%s; reported-pane=%s\n"
    (Window.Id.to_string (Window.Target.id created.window))
    (Pane.Id.to_string (Pane.Target.id created.pane))

let report_operation (operation : Created.t Operation.t) =
  match get (Operation.inspect operation) with
  | Operation.Finished (Ok created) ->
      print_endline "operation=finished";
      report_created created
  | Operation.Outcome_unknown receipt ->
      print_endline "operation=unknown";
      Format.printf "cause=%a@." Error.pp receipt.cause;
      List.iter report_created receipt.created;
      if receipt.owned_buffers <> [] then
        Printf.printf "unresolved-buffers=%d\n"
          (List.length receipt.owned_buffers)
  | Operation.Finished (Error error) ->
      Format.printf "operation=failed; cause=%a@." Error.pp error
  | Operation.Queued -> print_endline "operation=queued"
  | Operation.Not_started -> print_endline "operation=not-started"
  | Operation.Written -> print_endline "operation=written"
  | Operation.Acknowledged -> print_endline "operation=acknowledged"

let report_cleanup cleanup =
  let report = get (Cleanup.inspect cleanup) in
  Iarray.iter
    (fun issue ->
      match issue.Cleanup.error with
      | Some error -> Format.eprintf "cleanup: %a@." Error.pp error
      | None ->
          Format.eprintf "cleanup: %s@." (Printexc.to_string issue.exception_))
    report.issues;
  Printf.printf "cleanup-issues=%d; omitted=%d\n"
    (Iarray.length report.issues)
    report.omitted

let () =
  if Array.length Sys.argv <> 4 then (
    prerr_endline
      "usage: native_hook_recovery TMUX_BINARY SOCKET_PATH SESSION_ID";
    exit 2);
  let cleanup = Cleanup.create () and pending = ref None in
  protect
    ~finally:(fun () ->
      protect
        ~finally:(fun () -> report_cleanup cleanup)
        (fun () -> Option.iter report_operation !pending))
    (fun () ->
      let client =
        get
          (Client.connect ~cleanup ~binary:Sys.argv.(1)
             (Endpoint.socket_path Sys.argv.(2)))
      in
      protect
        ~finally:(fun () -> get (Client.close client))
        (fun () ->
          let id = get (Session.Id.of_string Sys.argv.(3)) in
          let session =
            match Snapshot.find_session (get (Client.capture client)) id with
            | Some session -> session
            | None -> failwith "requested session is absent from the capture"
          in
          let operation =
            get
              (Client.submit client
                 (Operations.create_window ~index:4 ~name:"hook-created"
                    ~spawn:
                      (Spawn.make
                         (Exec { program = "/bin/cat"; args = [ "-u" ] }))
                    (Session.target session)))
          in
          pending := Some operation;
          match Client.await operation with
          | Ok _ | Error (Error.Outcome_unknown _) -> ()
          | Error error -> failwith (Format.asprintf "%a" Error.pp error)))
```

To use this file outside the checkout, save it as `main.ml` in the Dune project
from [first use](getting-started.md#link-an-installed-library), linking
`libtmux` and `libtmux-unix`.

The reported IDs establish what tmux replied before the outcome became
uncertain. Resources can change afterward. Capture fresh observations and
choose a postcondition before deciding on another mutation. Targets from a
closed connection retain their old source generation; bind new targets through
the new capture. [Identity and graph navigation](graph.md) explains that scope.

Without the failing hook, the same program prints `operation=finished` and
the reported IDs. Installed-consumer checks execute both cases on tmux 3.3a
and 3.8, verify exactly one created window and its pane, and check client and
owned-fixture teardown. The literal commands above run against those installed
programs too.

[Waiter cancellation](recovery.md) · [Control](control.md) · [Guide](README.md)
