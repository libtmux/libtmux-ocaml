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
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: native_workspace_recovery TMUX_BINARY SOCKET_PATH";
    exit 2);
  Eio_main.run @@ fun env ->
  let endpoint = Endpoint.socket_path Sys.argv.(2) in
  let cleanup = Cleanup.create () and pending = ref None in
  protect
    ~finally:(fun () ->
      protect
        ~finally:(fun () -> report_cleanup cleanup)
        (fun () -> Option.iter report !pending))
    (fun () ->
      Eio.Switch.run @@ fun sw ->
      let connect () =
        get
          (Client.connect ~cleanup ~sw ~binary:Sys.argv.(1)
             ~process_mgr:(Eio.Stdenv.process_mgr env)
             ~mono_clock:(Eio.Stdenv.mono_clock env)
             endpoint)
      in
      let client = connect () in
      let observer = connect () in
      let execution = get (Workspace.submit client (plan client endpoint)) in
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
                      (fun (step : Execution.step) -> step.status = Skipped)
                      receipt.steps)
            then failwith "workspace interruption did not confirm compensation";
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
      if Option.is_some (Snapshot.find_session after created_session) then
        failwith "created workspace session remains present";
      print_endline "postcondition=created-session-absent")
