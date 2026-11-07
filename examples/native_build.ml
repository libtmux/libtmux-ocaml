open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin create-layout *)
let build client ~name ~directory =
  let spawn =
    Spawn.make ~cwd:directory
      ~environment:[ ("LIBTMUX_PROJECT", name) ]
      (Spawn.Exec { program = "cat"; args = [] })
  in
  let session =
    get (Client.create_session client ~name ~window_name:"editor" ~spawn ())
  in
  let right =
    get (Client.split_pane client session.pane ~direction:Geometry.Right ~spawn)
  in
  let logs =
    get (Client.create_window client session.session ~name:"logs" ~spawn)
  in
  get (Client.set_pane_title client right.pane ~title:"build output");
  get
    (Client.set_option client (Options.Session session.session) ~name:"@project"
       (Options.Text name));
  (session, right, logs)
(* docs:end create-layout *)

let () =
  if Array.length Sys.argv <> 5 then (
    prerr_endline
      "usage: native_build TMUX_BINARY SOCKET_PATH SESSION_NAME DIRECTORY";
    exit 2);
  let client =
    get
      (Client.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2)))
  in
  Fun.protect
    ~finally:(fun () -> get (Client.close client))
    (fun () ->
      let session, right, logs =
        build client ~name:Sys.argv.(3) ~directory:Sys.argv.(4)
      in
      Printf.printf "session=%s\neditor=%s\nright=%s\nlogs=%s\n"
        (Session.Id.to_string (Session.Target.id session.session))
        (Window.Id.to_string (Window.Target.id session.window))
        (Pane.Id.to_string (Pane.Target.id right.pane))
        (Window.Id.to_string (Window.Target.id logs.window)))
