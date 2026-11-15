open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin steer-client *)
let same a b = Client_name.to_string a = Client_name.to_string b

let names client =
  Snapshot.clients (get (Client.capture client))
  |> Iarray.to_list
  |> List.map Client_observation.current_name

let observed client name =
  Snapshot.clients (get (Client.capture client))
  |> Iarray.to_seq
  |> Seq.find (fun observation ->
      same (Client_observation.current_name observation) name)

(* A second control client is the one this program steers. *)
let connect_second ~binary client =
  let before = names client in
  let second =
    get (Client.connect ~binary (Source.endpoint (Client.source client)))
  in
  let name =
    List.find (fun name -> not (List.exists (same name) before)) (names client)
  in
  (second, name)

let steer client name (other : Created.t) =
  get (Client.resize_control_client_at client name ~width:100 ~height:30);
  get (Client.refresh_client_at client name);
  get (Client.switch_client_at client name ~session:other.session);
  let steered = Option.get (observed client name) in
  assert (Client_observation.width steered = 100);
  assert (
    Session.Id.equal
      (Session.id (Option.get (Client_observation.session steered)))
      (Session.Target.id other.session));
  get (Client.request_detach_client_at client name);
  assert (observed client name = None)
(* docs:end steer-client *)

let control binary client (_initial : Created.t) _spawn =
  let other = get (Client.create_session client ~name:"other" ()) in
  let second, name = connect_second ~binary client in
  steer client name other;
  (* The detached client reports its own loss when it closes. *)
  ignore (Client.close second);
  print_endline "steered: resized, refreshed, switched and detached"

module Workspace = Libtmux_unix.Workspace
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan
module Execution = Libtmux_workspace.Execution

let with_demo binary use =
  let channel = Unix.open_process_args_in binary [| binary; "-V" |] in
  let version =
    Fun.protect
      ~finally:(fun () ->
        if Unix.close_process_in channel <> Unix.WEXITED 0 then
          failwith "tmux version discovery failed")
      (fun () -> String.trim (input_line channel))
  in
  if not (String.starts_with ~prefix:"tmux " version) then
    failwith "invalid tmux version";
  let version = String.sub version 5 (String.length version - 5) in
  let spawn =
    Spawn.make
      (Exec
         {
           program = "/bin/sh";
           args = [ "-c"; "echo 'showcase ready'; exec cat -u" ];
         })
  in
  let config =
    match
      Config.make ~directory:(Sys.getcwd ()) ~session:"showcase"
        [ Config.window ~name:"editor" [ Config.pane ~spawn () ] ]
    with
    | Ok value -> value
    | Error error -> failwith (Format.asprintf "%a" Config.pp_error error)
  in
  get
    (Libtmux_unix.with_private_daemon ~binary (fun endpoint ->
         let plan =
           match Plan.make ~endpoint ~version ~observed:None config with
           | Ok value -> value
           | Error error -> failwith (Format.asprintf "%a" Plan.pp_error error)
         in
         let operation = get (Workspace.submit_bootstrap ~binary plan) in
         Fun.protect
           ~finally:(fun () -> get (Workspace.close operation))
           (fun () ->
             let receipt = get (Workspace.await operation) in
             if receipt.status <> Execution.Succeeded then
               failwith "workspace setup failed";
             let client = Option.get (Workspace.client operation) in
             let initial = List.hd (Iarray.get receipt.steps 0).created in
             (match Endpoint.kind endpoint with
             | Endpoint.Socket_path socket ->
                 Printf.printf "socket=%s\n%!" socket
             | Endpoint.Named_socket _ -> ());
             let pane =
               Snapshot.find_pane
                 (get (Client.capture client))
                 (Pane.Target.id initial.pane)
               |> Option.get
             in
             ignore
               (get
                  (Client.wait_for_text ~timeout:0.5 client pane
                     ~text:"showcase ready"));
             use client initial spawn)))

let () =
  let binary = if Array.length Sys.argv = 2 then Sys.argv.(1) else "tmux" in
  with_demo binary (control binary)
