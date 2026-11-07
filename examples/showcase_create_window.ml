open Libtmux
module Client = Libtmux_unix.Client
module Workspace = Libtmux_unix.Workspace
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan
module Execution = Libtmux_workspace.Execution

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let create_window client (initial : Created.t) spawn =
  let created =
    get (Client.create_window client initial.session ~name:"logs" ~spawn)
  in
  let window =
    Snapshot.find_window
      (get (Client.capture client))
      (Window.Target.id created.window)
    |> Option.get
  in
  assert (Window.name window = "logs");
  Printf.printf "created: %s\n" (Window.name window)

let with_demo binary use =
  let directory = Filename.temp_dir "libtmux-ocaml-showcase-" "" in
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir directory
      |> Array.iter (fun name -> Sys.remove (Filename.concat directory name));
      Unix.rmdir directory)
    (fun () ->
      let socket = Filename.concat directory "server" in
      (* Give this private daemon a lifetime even if startup fails. *)
      let config_file = Filename.concat directory "tmux.conf" in
      Out_channel.with_open_text config_file (fun output ->
          output_string output "set-option -s exit-unattached on\n");
      let wrapper = Filename.concat directory "tmux" in
      Out_channel.with_open_text wrapper (fun output ->
          Printf.fprintf output "#!/bin/sh\nexec %s -f %s \"$@\"\n"
            (Filename.quote binary)
            (Filename.quote config_file));
      Unix.chmod wrapper 0o700;
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
      let ready = Filename.concat directory "ready.txt" in
      Out_channel.with_open_text ready (fun output ->
          output_string output "showcase ready\n");
      let spawn =
        Spawn.make (Exec { program = "/bin/cat"; args = [ "-u"; ready; "-" ] })
      in
      let config =
        match
          Config.make ~directory ~session:"showcase"
            [ Config.window ~name:"editor" [ Config.pane ~spawn () ] ]
        with
        | Ok value -> value
        | Error error -> failwith (Format.asprintf "%a" Config.pp_error error)
      in
      let plan =
        match
          Plan.make
            ~endpoint:(Endpoint.socket_path socket)
            ~version ~observed:None config
        with
        | Ok value -> value
        | Error error -> failwith (Format.asprintf "%a" Plan.pp_error error)
      in
      let operation = get (Workspace.submit_bootstrap ~binary:wrapper plan) in
      Fun.protect
        ~finally:(fun () -> get (Workspace.close operation))
        (fun () ->
          let receipt = get (Workspace.await operation) in
          if receipt.status <> Execution.Succeeded then
            failwith "workspace setup failed";
          let client = Option.get (Workspace.client operation) in
          let initial = List.hd (Iarray.get receipt.steps 0).created in
          Printf.printf "socket=%s\n%!" socket;
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
          use client initial spawn))

let () =
  let binary = if Array.length Sys.argv = 2 then Sys.argv.(1) else "tmux" in
  with_demo binary create_window
