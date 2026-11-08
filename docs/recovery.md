# Recover an operation after cancelling its waiter

Retain the operation handle before awaiting it. Cancelling one Eio waiter leaves
admitted work under the client's ownership. Inspect that handle, await its
outcome and check the relevant server state before choosing another mutation.

This program uses a tmux `wait-for` barrier to keep an operation pending while
its waiter is cancelled. It then signals the barrier once and awaits the same
handle. A fresh capture checks the window's name before renaming it. The barrier
coordinates this example; it does not establish completion of a terminal
program. [Control](control.md) compares Eio and blocking cancellation timing.

## Run the complete program

Complete the [source installation](getting-started.md) and run from the cloned
repository. Start an empty private server:

```console
$ export LIBTMUX_RECOVERY_DIR="$(mktemp -d -t libtmux-ocaml-recovery.XXXXXX)"
```

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_RECOVERY_DIR/server" \
    -f /dev/null \
    new-session \
    -d \
    -s recovery-demo \
    -- "exec cat"
```

The fresh server's session ID is `$0`; quote it to preserve the literal ID:

```console
$ opam exec -- dune exec examples/native_recovery.exe -- \
    tmux "$LIBTMUX_RECOVERY_DIR/server" '$0'
```

Expected output is `waiter=cancelled; operation=retained`, followed by
`operation=finished; postcondition=recovery-complete`. The program creates a
window and removes its own pane afterward. It preserves the seed session and
other panes, and closes its client on success or failure.

Remove the private seed session and directory:

```console
$ env -u TMUX -u TMUX_PANE tmux \
    -S "$LIBTMUX_RECOVERY_DIR/server" \
    kill-session \
    -t '=recovery-demo'
```

```console
$ rm -f -- "$LIBTMUX_RECOVERY_DIR/server"
```

```console
$ rmdir "$LIBTMUX_RECOVERY_DIR"
```

## Inspect before acting

The [complete source](../examples/native_recovery.ml) uses installed public
libraries. Its Eio cancellation scope covers only the waiter. Client ownership
and cleanup remain outside that scope.

<!-- example: examples/native_recovery.ml -->

```ocaml
open Libtmux
module Client = Libtmux_eio.Client
module Operation = Libtmux_eio.Operation

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

let cancel_waiter operation =
  let entered, enter = Eio.Promise.create () in
  let context = ref None in
  Eio.Fiber.pair
    (fun () ->
      try
        Eio.Cancel.sub (fun current ->
            context := Some current;
            Eio.Promise.resolve enter ();
            ignore (get (Client.await operation));
            failwith "wait completed before its release signal")
      with Eio.Cancel.Cancelled Exit -> ())
    (fun () ->
      Eio.Promise.await entered;
      Eio.Cancel.cancel (Option.get !context) Exit)
  |> ignore

let recover client session =
  let created =
    get
      (Client.create_window client session ~name:"recovery-pending"
         ~spawn:(Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] })))
  in
  let channel =
    "libtmux-recovery-"
    ^ Generation.to_string (Source.generation (Client.source client))
  in
  let pending = ref None and release_attempted = ref false in
  let release () =
    if not !release_attempted then (
      release_attempted := true;
      get (Client.signal client channel))
  in
  protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () ->
          protect
            ~finally:(fun () -> get (Client.kill_pane client created.pane))
            (fun () ->
              match !pending with
              | None -> ()
              | Some operation -> (
                  match get (Operation.inspect operation) with
                  | Operation.Queued -> get (Operation.cancel operation)
                  | Operation.Written | Operation.Acknowledged ->
                      release ();
                      get (Client.await operation)
                  | Operation.Not_started | Operation.Finished _
                  | Operation.Outcome_unknown _ ->
                      ()))))
    (fun () ->
      let operation =
        get (Client.submit client (Operations.wait_for channel))
      in
      pending := Some operation;
      ignore (get (Operation.await_stage operation `Acknowledged));
      cancel_waiter operation;
      (match get (Operation.inspect operation) with
      | Operation.Written | Operation.Acknowledged -> ()
      | Operation.Outcome_unknown receipt ->
          failwith
            (Format.asprintf "outcome unknown: %a" Error.pp receipt.cause)
      | _ -> failwith "expected a retained in-flight operation");
      print_endline "waiter=cancelled; operation=retained";
      release ();
      get (Client.await operation);
      (match get (Operation.inspect operation) with
      | Operation.Finished (Ok ()) -> ()
      | _ -> failwith "retained operation did not finish");
      let window =
        Snapshot.find_window
          (get (Client.capture client))
          (Window.Target.id created.window)
        |> Option.get
      in
      if Window.name window <> "recovery-pending" then
        failwith "postcondition changed; leave the next action to the caller";
      get
        (Client.rename_window client (Window.target window)
           ~name:"recovery-complete");
      let after =
        Snapshot.find_window (get (Client.capture client)) (Window.id window)
        |> Option.get
      in
      assert (Window.name after = "recovery-complete");
      Printf.printf "operation=finished; postcondition=%s\n" (Window.name after))

let () =
  if Array.length Sys.argv <> 4 then (
    prerr_endline "usage: native_recovery TMUX_BINARY SOCKET_PATH SESSION_ID";
    exit 2);
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    get
      (Client.connect ~sw ~binary:Sys.argv.(1)
         ~process_mgr:(Eio.Stdenv.process_mgr env)
         ~mono_clock:(Eio.Stdenv.mono_clock env)
         (Endpoint.socket_path Sys.argv.(2)))
  in
  protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> get (Client.close client)))
    (fun () ->
      let id = get (Session.Id.of_string Sys.argv.(3)) in
      let session =
        Snapshot.find_session (get (Client.capture client)) id |> Option.get
      in
      recover client (Session.target session))
```

The release attempt is recorded before its I/O so cleanup cannot retry an
uncertain signal. The finally block cancels queued work, releases and drains a
live barrier, and removes only the pane whose creation was reported. Existing
panes remain outside that cleanup. A primary failure keeps its original
exception and backtrace; a later cleanup failure is reported separately. Both clients and operations stay on the
connecting domain.

## Interpret a retained state

[`Libtmux_eio.Operation.inspect`](../eio/libtmux_eio.mli) performs no I/O and
remains readable after client closure. A state describes this operation; it
does not prove a terminal program consumed input or exited.

| State | Next decision |
| --- | --- |
| `Queued` | Cancel before writing, or continue awaiting the same handle. |
| `Not_started` | The operation made no admitted effect; establish fresh preconditions before a new action. |
| `Written` or `Acknowledged` | Keep the handle. The client still owns completion; cancelling another waiter does not undo the write. |
| `Finished (Ok value)` | Use the result and check the task's relevant postcondition. |
| `Finished (Error error)` | Examine the error and current state; a later command or hook failure can follow an earlier effect. |
| `Outcome_unknown receipt` | Preserve the cause and reported creations. Reacquire observations explicitly and resolve uncertainty before another mutation. |

The example exercises active-waiter cancellation and retained completion. Its
unknown-outcome branch reports the cause and stops the next action. Transport
loss, a replacement daemon and uncertain mutation recovery require the retained
receipt and fresh observation; this program does not simulate those failures.
Closing a client does not terminate a borrowed tmux daemon.

For workspace automation, inspect the [execution receipt](workspaces.md#collisions-and-recovery)
and compensate only proven creations. For stream continuity loss, handle the
[Gap or End event](streaming.md) before choosing a fresh subscription.

[First use](getting-started.md) · [Control](control.md) · [Guide](README.md)
