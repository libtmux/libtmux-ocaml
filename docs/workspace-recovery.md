# Interrupt a workspace and inspect its journal

Eio cancellation interrupts the remaining workspace steps. The client still
owns written commands, and the workspace attempts protected compensation for
reported creations. Keep the execution handle outside the cancellation and
client lifetimes, then read `Libtmux_eio.Workspace.inspect` after cleanup.

This program plans two windows, interrupts the first creation at a tmux hook,
and checks that the reported session ID is absent after compensation. Its final
journal remains readable after the Eio switch closes both clients.
See [compatibility](compatibility.md) for current qualification limits.

## Run the complete program

Complete the [source installation](getting-started.md), then run from the
checkout. The program starts a private server with a `workspace-seed` session,
pauses the first workspace creation at an `after-new-session` hook, and stops
the server when it finishes:

```console
$ opam exec -- dune exec examples/native_workspace_recovery.exe -- tmux
```

Expected output:

```text
waiter=cancelled
postcondition=created-session-absent
journal=interrupted
compensated-pane=%1
cleanup-issues=0; omitted=0
```

The `first` window was created; the `skipped` window was never applied. The
seed session keeps the daemon alive while compensation removes the created
session, and the library removes the daemon and its directory afterward.

## Own the switch and retain the journal

The applying client executes the plan. A separate client waits for the hook,
cancels the workspace waiter and releases the hook. That release lets the
written creation settle and compensation proceed. The hook coordinates tmux
commands; define pane-program readiness separately.

The application owns [`Eio_main`][eio-main] and its switch. The switch closes
both clients. Closing the borrowed workspace handle leaves its client available
for the postcondition capture. The outer finalizer inspects the journal after
those client cleanup scopes, preserving the primary exception if reporting also
fails.

If a foreign window is linked into the new session, compensation leaves that
window intact. The program's ID-based check reports a surviving session even
if another client renamed it.

[eio-main]: https://ocaml-multicore.github.io/eio/eio_main/Eio_main/index.html

<!-- example: examples/native_workspace_recovery.ml -->

```ocaml
open Libtmux
module Client = Libtmux_eio.Client
module Workspace = Libtmux_eio.Workspace
module Cleanup = Libtmux_eio.Cleanup
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan
module Execution = Libtmux_workspace.Execution

exception Interrupt_workspace

let checked pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let get result = checked Error.pp result

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

let plan client endpoint =
  let spawn = Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] }) in
  let window name = Config.window ~name [ Config.pane ~spawn () ] in
  let config =
    Config.make ~directory:(Sys.getcwd ()) ~session:"workspace-interrupt"
      [ window "first"; window "skipped" ]
    |> checked Config.pp_error
  in
  Plan.make ~endpoint ~version:(Client.version client)
    ~observed:(Some (get (Client.capture client)))
    config
  |> checked Plan.pp_error

let interrupt execution observer =
  let entered, enter = Eio.Promise.create () in
  Eio.Fiber.pair
    (fun () ->
      try
        Eio.Cancel.sub (fun scope ->
            Eio.Promise.resolve enter scope;
            ignore (get (Workspace.await execution));
            failwith "workspace finished before interruption")
      with Eio.Cancel.Cancelled Interrupt_workspace ->
        print_endline "waiter=cancelled")
    (fun () ->
      let scope = Eio.Promise.await entered in
      protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () ->
              get (Client.signal observer "libtmux-workspace-release")))
        (fun () ->
          get (Client.wait_for observer "libtmux-workspace-ready");
          Eio.Cancel.cancel scope Interrupt_workspace))
  |> ignore

let report execution =
  let receipt = get (Workspace.inspect execution) in
  let status =
    match receipt.status with
    | Execution.Queued -> "queued"
    | Applying -> "applying"
    | Succeeded -> "succeeded"
    | Partial -> "partial"
    | Interrupted -> "interrupted"
    | Rejected error -> Format.asprintf "rejected: %a" Plan.pp_error error
    | Unavailable error -> Format.asprintf "unavailable: %a" Error.pp error
  in
  Printf.printf "journal=%s\n" status;
  Iarray.iter
    (fun (step : Execution.step) ->
      match step.status with
      | Execution.Failed error | Execution.Uncertain error ->
          Format.eprintf "step %d: %a@." step.index Error.pp error
      | _ -> ())
    receipt.steps;
  Iarray.iter
    (fun (cleanup : Execution.cleanup) ->
      let id = Pane.Id.to_string (Pane.Target.id cleanup.pane) in
      match cleanup.outcome with
      | Ok () -> Printf.printf "compensated-pane=%s\n" id
      | Error error -> Format.eprintf "compensation %s: %a@." id Error.pp error)
    receipt.cleanup;
  Option.iter
    (fun error -> Format.eprintf "compensation: %a@." Error.pp error)
    receipt.cleanup_error

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
  let binary = if Array.length Sys.argv = 2 then Sys.argv.(1) else "tmux" in
  Eio_main.run @@ fun env ->
  let process_mgr = Eio.Stdenv.process_mgr env
  and mono_clock = Eio.Stdenv.mono_clock env in
  let cleanup = Cleanup.create () and pending = ref None in
  protect
    ~finally:(fun () ->
      protect
        ~finally:(fun () -> report_cleanup cleanup)
        (fun () -> Option.iter report !pending))
    (fun () ->
      (* The seed session keeps the daemon's workspace compensation visible. *)
      get
        (Libtmux_eio.with_private_daemon ~cleanup ~binary
           ~session:"workspace-seed" ~process_mgr ~mono_clock (fun endpoint ->
             Eio.Switch.run @@ fun sw ->
             let connect () =
               get
                 (Client.connect ~cleanup ~sw ~binary ~process_mgr ~mono_clock
                    endpoint)
             in
             let client = connect () in
             let observer = connect () in
             (* Pause the first workspace creation at its hook. *)
             get
               (Client.set_hook client Options.Global_sessions
                  ~name:"after-new-session"
                  [
                    {
                      Hook.name = "wait-for";
                      arguments = [ "-S"; "libtmux-workspace-ready" ];
                    };
                    {
                      Hook.name = "wait-for";
                      arguments = [ "libtmux-workspace-release" ];
                    };
                  ]);
             let execution =
               get (Workspace.submit client (plan client endpoint))
             in
             pending := Some execution;
             let created_session =
               protect
                 ~finally:(fun () -> get (Workspace.close execution))
                 (fun () ->
                   interrupt execution observer;
                   let receipt = get (Workspace.inspect execution) in
                   if
                     receipt.status <> Execution.Interrupted
                     || Iarray.length receipt.cleanup <> 1
                     || Result.is_error (Iarray.get receipt.cleanup 0).outcome
                     || Option.is_some receipt.cleanup_error
                     || not
                          (Iarray.exists
                             (fun (step : Execution.step) ->
                               step.status = Skipped)
                             receipt.steps)
                   then
                     failwith
                       "workspace interruption did not confirm compensation";
                   receipt.steps |> Iarray.to_seq
                   |> Seq.filter_map (fun (step : Execution.step) ->
                       match (step.action, step.created) with
                       | Plan.Create_session _, [ created ] ->
                           Some (Session.Target.id created.session)
                       | _ -> None)
                   |> Query.exactly_one
                   |> checked Cardinality.pp_error)
             in
             let after = get (Client.capture client) in
             if Option.is_some (Snapshot.find_session after created_session)
             then failwith "created workspace session remains present";
             print_endline "postcondition=created-session-absent")))
```

The [complete source](../examples/native_workspace_recovery.ml) uses native
workspace builders and optional Eio support. To use it outside this checkout,
save it as `main.ml` in the project from
[first use](getting-started.md#link-an-installed-library), linking `libtmux`,
`libtmux-workspace`, `libtmux-eio` and `eio_main`.

## Interpret compensation conservatively

The journal lives in process memory. One execution handle applies its steps
at most once; a new handle or invocation is a new execution. Printed or exported
receipts retain evidence rather than authority to mutate a later connection.

Compensation removes proven newly created panes. Programs can already have
changed files or contacted other services; those effects remain. Inspect failed
or uncertain steps, cleanup outcomes and fresh server state before choosing
another mutation. The [workspace guide](workspaces.md#collisions-and-recovery)
defines those receipts and limits.

[Waiter recovery](recovery.md) · [Hook recovery](hook-recovery.md) · [Guide](README.md)
