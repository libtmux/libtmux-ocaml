open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin arrange-panes *)
let find client target =
  Snapshot.find_pane (get (Client.capture client)) (Pane.Target.id target)
  |> Option.get

let panes_in client (window : Window.target) =
  Window.panes
    (Snapshot.find_window
       (get (Client.capture client))
       (Window.Target.id window)
    |> Option.get)

let arrange client (initial : Created.t) spawn =
  let right =
    get (Client.split_pane client initial.pane ~direction:Geometry.Right ~spawn)
  in
  let below =
    get (Client.split_pane client right.pane ~direction:Geometry.Below ~spawn)
  in
  assert (Iarray.length (panes_in client initial.window) = 3);
  (* Swap two panes, rotate all three and choose the active one. *)
  let left target = Pane.left (find client target) in
  let before = left initial.pane in
  get (Client.swap_panes client initial.pane right.pane);
  assert (left initial.pane <> before);
  get (Client.rotate_panes client initial.window `Forward);
  get (Client.select_pane client right.pane);
  assert (Pane.active (find client right.pane));
  (* Zoom one pane over the window, restore it and cycle the layout. *)
  get (Client.zoom_pane client right.pane);
  let zoomed = find client right.pane in
  assert (Pane.width zoomed = Window.width (Pane.window zoomed));
  get (Client.zoom_pane client right.pane);
  get (Client.cycle_layout client initial.window `Next);
  (* Move a pane beside another, then break it into a new window. *)
  get
    (Client.move_pane client below.pane ~beside:initial.pane
       ~direction:Geometry.Below);
  let broken =
    get
      (Client.break_pane client below.pane ~name:"broken"
         ~session:initial.session ~index:5)
  in
  assert (broken.window_index = 5);
  assert (Iarray.length (panes_in client initial.window) = 2)
(* docs:end arrange-panes *)

(* docs:begin restart-pane *)
let restart client (pane : Pane.target) spawn =
  get (Client.respawn_pane client ~kill_running:true pane spawn);
  get (Client.clear_history client pane)
(* docs:end restart-pane *)

let rearrange client (initial : Created.t) spawn =
  arrange client initial spawn;
  restart client initial.pane spawn;
  print_endline "arranged: swap, rotate, zoom, cycle, move, break, respawn"

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
  with_demo binary rearrange
