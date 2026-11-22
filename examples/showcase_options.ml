open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin options-and-environment *)
let integer client scope name =
  match get (Client.read_option client scope name) with
  | Some (Options.Scalar (Options.Integer value)) -> Int64.to_int value
  | _ -> failwith (name ^ " is not an integer")

let tune_options client (initial : Created.t) =
  let server = Options.Server and session = Options.Session initial.session in
  get
    (Client.set_option client server ~name:"escape-time" (Options.Integer 13L));
  assert (integer client server "escape-time" = 13);
  (* Unsetting restores tmux's default, which differs between releases. *)
  get (Client.unset_option client server "escape-time");
  assert (integer client server "escape-time" <> 13);
  let name = "@project" in
  get (Client.set_option client session ~name (Options.Text "ocaml"));
  assert (
    Options.lookup (get (Client.capture_options client session)) name <> None);
  get (Client.clear_option_array client server "command-alias")

let tune_environment client =
  let global = Environment.Global and name = "LIBTMUX_DEMO" in
  let lookup () =
    Environment.lookup (get (Client.capture_environment client global)) name
  in
  get (Client.set_environment client global ~name "one");
  assert (lookup () = Some (Environment.Value "one"));
  (* A removal marker masks a global value; unsetting drops the entry. *)
  get (Client.remove_environment client global name);
  assert (lookup () = Some Environment.Removed);
  get (Client.unset_environment client global name);
  assert (lookup () = None)
(* docs:end options-and-environment *)

(* docs:begin hooks *)
let run_hook client (initial : Created.t) =
  let name = "after-new-window" and scope = Options.Global_sessions in
  let configured = function
    | Some (Options.Array entries) -> Iarray.length entries > 0
    | Some (Options.Scalar _) -> true
    | None -> false
  in
  get
    (Client.set_hook client scope ~name
       [
         {
           Hook.name = "set-environment";
           arguments = [ "-g"; "LIBTMUX_HOOK"; "fired" ];
         };
       ]);
  assert (configured (get (Client.read_hook client scope name)));
  assert (Options.lookup (get (Client.capture_hooks client scope)) name <> None);
  get (Client.run_hook client (Options.Session initial.session) name);
  assert (
    Environment.lookup
      (get (Client.capture_environment client Environment.Global))
      "LIBTMUX_HOOK"
    = Some (Environment.Value "fired"));
  get (Client.remove_hook client scope name);
  assert (not (configured (get (Client.read_hook client scope name))))
(* docs:end hooks *)

let configure client initial _spawn =
  tune_options client initial;
  tune_environment client;
  run_hook client initial;
  print_endline "configured: options, hooks and environment"

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
  with_demo binary configure
