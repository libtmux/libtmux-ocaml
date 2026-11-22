open Libtmux
module Client = Libtmux_unix.Client
module Workspace = Libtmux_unix.Workspace
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan
module Execution = Libtmux_workspace.Execution

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let watch_output binary blocking (initial : Created.t) _spawn =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let module Client = Libtmux_eio.Client in
  let module Subscription = Libtmux_eio.Subscription in
  let client =
    get
      (Client.connect ~sw ~binary
         ~process_mgr:(Eio.Stdenv.process_mgr env)
         ~mono_clock:(Eio.Stdenv.mono_clock env)
         (Source.endpoint (Libtmux_unix.Client.source blocking)))
  in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> get (Client.close client)))
    (fun () ->
      let pane =
        Snapshot.find_pane
          (get (Client.capture client))
          (Pane.Target.id initial.pane)
        |> Option.get
      in
      let subscription =
        get (Client.subscribe ~capacity_bytes:4096 client pane)
      in
      Fun.protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () -> get (Subscription.close subscription)))
        (fun () ->
          let target = Pane.target pane in
          let cursor, () =
            Eio.Fiber.pair
              (fun () ->
                match
                  Subscription.wait_for_bytes ~timeout:0.5 subscription
                    ~text:"changed"
                with
                | Ok cursor -> cursor
                | Error (Output.Failure error) ->
                    failwith (Format.asprintf "%a" Error.pp error)
                | Error (Output.Ended reason) ->
                    failwith (Format.asprintf "%a" Output.reason_pp reason))
              (fun () ->
                get (Client.send_text client target ~text:"changed");
                get (Client.send_keys client target [ Key.Enter ]))
          in
          assert (cursor.offset >= 7L);
          print_endline "observed: changed"))

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
  with_demo binary (watch_output binary)
