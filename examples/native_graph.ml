open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin graph *)
let print_graph snapshot =
  Snapshot.sessions snapshot
  |> Iarray.iter (fun session ->
      Printf.printf "session %s %S\n"
        (Session.Id.to_string (Session.id session))
        (Session.name session);
      Session.window_links session
      |> Iarray.iter (fun link ->
          let window = Window_link.window link in
          Printf.printf "  window %s at %d %S\n"
            (Window.Id.to_string (Window.id window))
            (Window_link.index link) (Window.name window);
          Window.panes window
          |> Iarray.iter (fun pane ->
              Printf.printf "    pane %s active=%b %dx%d %S\n"
                (Pane.Id.to_string (Pane.id pane))
                (Pane.active pane) (Pane.width pane) (Pane.height pane)
                (Pane.current_command pane))))
(* docs:end graph *)

let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: native_graph TMUX_BINARY SOCKET_PATH";
    exit 2);
  let client =
    get
      (Client.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2)))
  in
  let snapshot =
    Fun.protect
      ~finally:(fun () -> get (Client.close client))
      (fun () -> get (Client.capture client))
  in
  print_graph snapshot
