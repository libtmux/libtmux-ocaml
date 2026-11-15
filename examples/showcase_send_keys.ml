(* docs:begin pane-io *)
open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let find client target =
  Snapshot.find_pane (get (Client.capture client)) (Pane.Target.id target)
  |> Option.get

let wait client pane text =
  ignore (get (Client.wait_for_text ~timeout:0.5 client pane ~text))

let drive client (initial : Created.t) spawn =
  let right =
    get (Client.split_pane client initial.pane ~direction:Geometry.Right ~spawn)
  in
  let pane = find client right.pane in
  wait client pane "showcase ready";
  let text = "literal: $HOME; #{pane_id}" in
  get (Client.send_text client right.pane ~text);
  get (Client.send_keys client right.pane [ Key.Enter ]);
  wait client pane text;
  let screen = get (Client.capture_text client pane ~start:0 ~end_:1) in
  Printf.printf "sent: %s\ncaptured: %S\n" text screen.bytes;
  get (Client.resize_window client initial.window ~width:100 ~height:30);
  get (Client.resize_pane client right.pane ~width:20);
  let resized = find client right.pane in
  Printf.printf "resized: %dx%d\n" (Pane.width resized) (Pane.height resized)
(* docs:end pane-io *)

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
  with_demo binary drive
