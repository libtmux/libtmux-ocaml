(* Drives with_private_daemon, Workspace.submit_bootstrap ?config_file and
   Client.kill_server from the Unix and Eio backends. The Python driver checks
   the effects outside this process. *)
open Libtmux
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let checked pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let version binary =
  let input = Unix.open_process_args_in binary [| binary; "-V" |] in
  let text = String.trim (input_line input) in
  ignore (Unix.close_process_in input);
  String.sub text 5 (String.length text - 5)

let plan binary endpoint =
  let spawn = Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] }) in
  let config =
    Config.make ~directory:(Sys.getcwd ()) ~session:"seed"
      [ Config.window ~name:"editor" [ Config.pane ~spawn () ] ]
    |> checked Config.pp_error
  in
  Plan.make ~endpoint ~version:(version binary) ~observed:None config
  |> checked Plan.pp_error

type bound = {
  pid : int;
  create_session : unit -> unit;
  escape_time : unit -> int option;
  capture : unit -> (Snapshot.t, Error.t) result;
  kill_server : unit -> (unit, Error.t) result;
}

let escape_time read =
  match get (read Options.Server "escape-time") with
  | Some (Options.Scalar (Options.Integer value)) -> Some (Int64.to_int value)
  | _ -> None

let directory_of endpoint =
  match Endpoint.kind endpoint with
  | Endpoint.Socket_path path -> Filename.dirname path
  | Endpoint.Named_socket _ -> failwith "expected a socket path"

let exercise ~mode ~directory bound =
  match mode with
  | "kill" ->
      get (bound.kill_server ());
      (match bound.capture () with
      | Error (Error.Closed | Error.Disconnected _) -> ()
      | Ok _ -> failwith "a killed server answered a capture"
      | Error error ->
          failwith (Format.asprintf "unexpected error: %a" Error.pp error));
      Printf.printf "KILLED %d\n%!" bound.pid
  | "config" | "bootstrap-config" ->
      assert (bound.escape_time () = Some 13);
      if mode = "bootstrap-config" then get (bound.kill_server ());
      Printf.printf "CONFIG %d\n%!" bound.pid
  | _ ->
      bound.create_session ();
      Printf.printf "READY %d %s\n%!" bound.pid directory;
      assert (input_line stdin = "continue");
      if mode = "raise" then failwith "boom"

let unix_bound client =
  let module Client = Libtmux_unix.Client in
  {
    pid = Source.server_pid (Client.source client);
    create_session =
      (fun () -> ignore (get (Client.create_session client ~name:"second" ())));
    escape_time = (fun () -> escape_time (Client.read_option client));
    capture = (fun () -> Client.capture client);
    kill_server = (fun () -> Client.kill_server client);
  }

let eio_bound client =
  let module Client = Libtmux_eio.Client in
  {
    pid = Source.server_pid (Client.source client);
    create_session =
      (fun () -> ignore (get (Client.create_session client ~name:"second" ())));
    escape_time = (fun () -> escape_time (Client.read_option client));
    capture = (fun () -> Client.capture client);
    kill_server = (fun () -> Client.kill_server client);
  }

let session_names snapshot =
  Snapshot.sessions snapshot |> Iarray.to_list |> List.map Session.name

let session_names snapshot =
  Snapshot.sessions snapshot |> Iarray.to_list |> List.map Session.name

let unix_run ~binary ~mode ~config_file ~socket =
  let module Workspace = Libtmux_unix.Workspace in
  let bootstrap ?config_file endpoint use =
    let operation =
      get
        (Workspace.submit_bootstrap ?config_file ~binary (plan binary endpoint))
    in
    Fun.protect
      ~finally:(fun () -> get (Workspace.close operation))
      (fun () ->
        ignore (get (Workspace.await operation));
        use (unix_bound (Option.get (Workspace.client operation))))
  in
  match socket with
  | _ when mode = "session" ->
      get
        (Libtmux_unix.with_private_daemon ~binary ~session:"seeded"
           (fun endpoint ->
             let module Client = Libtmux_unix.Client in
             let client = get (Client.connect ~binary endpoint) in
             Fun.protect
               ~finally:(fun () -> get (Client.close client))
               (fun () ->
                 assert (
                   session_names (get (Client.capture client)) = [ "seeded" ]);
                 Printf.printf "SEEDED %d\n%!"
                   (Source.server_pid (Client.source client)))))
  | Some path ->
      bootstrap ?config_file
        (Endpoint.socket_path path)
        (exercise ~mode ~directory:"")
  | None ->
      let cleanup = Libtmux_unix.Cleanup.create () in
      get
        (Libtmux_unix.with_private_daemon ~cleanup ~binary ?config_file
           (fun endpoint ->
             bootstrap endpoint
               (exercise ~mode ~directory:(directory_of endpoint))));
      assert (
        Iarray.length (get (Libtmux_unix.Cleanup.inspect cleanup)).issues = 0)

let eio_run ~binary ~mode ~config_file ~socket =
  Eio_main.run @@ fun env ->
  let module Workspace = Libtmux_eio.Workspace in
  let process_mgr = Eio.Stdenv.process_mgr env
  and mono_clock = Eio.Stdenv.mono_clock env in
  let bootstrap ?config_file endpoint use =
    Eio.Switch.run @@ fun sw ->
    let operation =
      get
        (Workspace.submit_bootstrap ?config_file ~sw ~binary ~process_mgr
           ~mono_clock (plan binary endpoint))
    in
    Fun.protect
      ~finally:(fun () -> get (Workspace.close operation))
      (fun () ->
        ignore (get (Workspace.await operation));
        use (eio_bound (Option.get (Workspace.client operation))))
  in
  match socket with
  | _ when mode = "session" ->
      get
        (Libtmux_eio.with_private_daemon ~binary ~session:"seeded" ~process_mgr
           ~mono_clock (fun endpoint ->
             Eio.Switch.run @@ fun sw ->
             let module Client = Libtmux_eio.Client in
             let client =
               get
                 (Client.connect ~sw ~binary ~process_mgr ~mono_clock endpoint)
             in
             Fun.protect
               ~finally:(fun () -> get (Client.close client))
               (fun () ->
                 assert (
                   session_names (get (Client.capture client)) = [ "seeded" ]);
                 Printf.printf "SEEDED %d\n%!"
                   (Source.server_pid (Client.source client)))))
  | Some path ->
      bootstrap ?config_file
        (Endpoint.socket_path path)
        (exercise ~mode ~directory:"")
  | None ->
      get
        (Libtmux_eio.with_private_daemon ~binary ?config_file ~process_mgr
           ~mono_clock (fun endpoint ->
             bootstrap endpoint
               (exercise ~mode ~directory:(directory_of endpoint))))

(* usage: private_daemon_peer BINARY unix|eio MODE [CONFIG_FILE [SOCKET]] *)
let () =
  let binary = Sys.argv.(1)
  and backend = Sys.argv.(2)
  and mode = Sys.argv.(3) in
  let argument index =
    if Array.length Sys.argv > index then Some Sys.argv.(index) else None
  in
  let config_file = argument 4 and socket = argument 5 in
  let run = if backend = "eio" then eio_run else unix_run in
  match run ~binary ~mode ~config_file ~socket with
  | () -> print_endline "DONE"
  | exception Failure message when mode = "raise" ->
      Printf.printf "RAISED %s\n%!" message
