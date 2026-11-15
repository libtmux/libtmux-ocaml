open Libtmux
module Client = Libtmux_eio.Client
module Operation = Libtmux_eio.Operation
module Cleanup = Libtmux_eio.Cleanup

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin preserve-primary *)
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
(* docs:end preserve-primary *)

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

let session_named snapshot name =
  Snapshot.sessions snapshot |> Iarray.to_seq
  |> Seq.find (fun session -> Session.name session = name)
  |> Option.get

let () =
  let binary = if Array.length Sys.argv = 2 then Sys.argv.(1) else "tmux" in
  Eio_main.run @@ fun env ->
  let process_mgr = Eio.Stdenv.process_mgr env
  and mono_clock = Eio.Stdenv.mono_clock env in
  let cleanup = Cleanup.create () in
  protect
    ~finally:(fun () ->
      let report = get (Cleanup.inspect cleanup) in
      Iarray.iter
        (fun issue ->
          match issue.Cleanup.error with
          | Some error -> Format.eprintf "cleanup: %a@." Error.pp error
          | None ->
              Format.eprintf "cleanup: %s@."
                (Printexc.to_string issue.exception_))
        report.issues;
      Printf.printf "cleanup-issues=%d; omitted=%d\n"
        (Iarray.length report.issues)
        report.omitted)
    (fun () ->
      get
        (Libtmux_eio.with_private_daemon ~cleanup ~binary
           ~session:"recovery-demo" ~process_mgr ~mono_clock (fun endpoint ->
             Eio.Switch.run @@ fun sw ->
             let client =
               get
                 (Client.connect ~cleanup ~sw ~binary ~process_mgr ~mono_clock
                    endpoint)
             in
             protect
               ~finally:(fun () ->
                 Eio.Cancel.protect (fun () -> get (Client.close client)))
               (fun () ->
                 let session =
                   session_named (get (Client.capture client)) "recovery-demo"
                 in
                 recover client (Session.target session)))))
