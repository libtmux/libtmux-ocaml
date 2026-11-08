open Libtmux
module Client = Libtmux_unix.Client
module Workspace = Libtmux_unix.Workspace
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan
module Execution = Libtmux_workspace.Execution

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

(* docs:begin bootstrap *)
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
(* docs:end bootstrap *)

let require_success (receipt : Execution.receipt) =
  if receipt.status <> Execution.Succeeded then (
    Format.eprintf "workspace %s did not complete@." receipt.operation_id;
    (match receipt.status with
    | Execution.Rejected error -> Format.eprintf "%a@." Plan.pp_error error
    | Execution.Unavailable error -> Format.eprintf "%a@." Error.pp error
    | _ -> ());
    Iarray.iter
      (fun (step : Execution.step) ->
        match step.status with
        | Execution.Failed error | Execution.Uncertain error ->
            Format.eprintf "step %d: %a@." step.index Error.pp error
        | _ -> ())
      receipt.steps;
    Option.iter
      (fun error -> Format.eprintf "compensation: %a@." Error.pp error)
      receipt.cleanup_error;
    Iarray.iter
      (fun (cleanup : Execution.cleanup) ->
        match cleanup.outcome with
        | Ok () -> ()
        | Error error -> Format.eprintf "cleanup: %a@." Error.pp error)
      receipt.cleanup;
    failwith "bootstrap incomplete; no automatic retry")

let local_version binary =
  let input = Unix.open_process_args_in binary [| binary; "-V" |] in
  let version =
    protect
      ~finally:(fun () ->
        if Unix.close_process_in input <> Unix.WEXITED 0 then
          failwith "tmux version discovery failed")
      (fun () -> String.trim (input_line input))
  in
  if not (String.starts_with ~prefix:"tmux " version) then
    failwith "invalid tmux version";
  String.sub version 5 (String.length version - 5)

let () =
  let binary = if Array.length Sys.argv = 2 then Sys.argv.(1) else "tmux" in
  let directory = Filename.temp_dir "libtmux-ocaml-showcase-" "" in
  protect
    ~finally:(fun () ->
      Sys.readdir directory
      |> Array.iter (fun name -> Sys.remove (Filename.concat directory name));
      Unix.rmdir directory)
    (fun () ->
      let socket = Filename.concat directory "server" in
      let config_file = Filename.concat directory "tmux.conf" in
      Out_channel.with_open_text config_file (fun output ->
          output_string output "set-option -s exit-unattached on\n");
      let wrapper = Filename.concat directory "tmux" in
      Out_channel.with_open_text wrapper (fun output ->
          Printf.fprintf output "#!/bin/sh\nexec %s -f %s \"$@\"\n"
            (Filename.quote binary)
            (Filename.quote config_file));
      Unix.chmod wrapper 0o700;
      let execution =
        bootstrap ~binary:wrapper ~version:(local_version binary) ~directory
          (Endpoint.socket_path socket)
      in
      (* docs:begin await-bootstrap *)
      let snapshot =
        protect
          ~finally:(fun () -> get (Workspace.close execution))
          (fun () ->
            let receipt = get (Workspace.await execution) in
            require_success receipt;
            let client = Option.get (Workspace.client execution) in
            get (Client.capture client))
        (* docs:end await-bootstrap *)
      in
      assert (Iarray.length (Snapshot.sessions snapshot) = 1);
      assert (Iarray.length (Snapshot.windows snapshot) = 1);
      assert (Iarray.length (Snapshot.panes snapshot) = 1);
      assert (
        Session.name (Iarray.get (Snapshot.sessions snapshot) 0)
        = "bootstrap-demo");
      assert (Window.name (Iarray.get (Snapshot.windows snapshot) 0) = "editor");
      Printf.printf "socket=%s\n" socket;
      print_endline "bootstrapped: 1 session, 1 window, 1 pane")
