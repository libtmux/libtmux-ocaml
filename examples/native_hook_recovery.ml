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
