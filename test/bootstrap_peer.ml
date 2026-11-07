open Libtmux
module B = Libtmux_unix__Bootstrap
module C = Libtmux_unix__Connection
module Io = Libtmux_unix__Runtime_io

let start receipt io name =
  B.start receipt ~io ~binary:Sys.argv.(1)
    ~endpoint:(Endpoint.socket_path Sys.argv.(2))
    ~name ~window_name:"editor"
    ~spawn:(Spawn.make (Shell "exec cat"))
    ~width:120 ~height:40 ()

let () =
  let receipt = B.create () in
  let connection, created = start receipt Io.blocking "workspace-bootstrap" in
  Fun.protect
    ~finally:(fun () -> C.close connection)
    (fun () ->
      assert (match receipt.state with Bound _ -> true | _ -> false);
      assert (
        Source.equal connection.source (Session.Target.source created.session));
      let template = "#{pane_pid}" in
      let pane_pid =
        C.request connection "display-message"
          [
            "-p";
            "-t";
            Pane.Id.to_string (Pane.Target.id created.pane);
            template;
          ]
        |> String.trim
      in
      Printf.printf "READY %d %s\n%!"
        (Source.server_pid connection.source)
        pane_pid;
      assert (read_line () = "continue");
      let collision = B.create () in
      (match
         Io.protect (fun () ->
             start collision Io.blocking "workspace-bootstrap")
       with
      | Error (Error.Command_failed { command = "new-session"; _ }) -> ()
      | _ -> failwith "bootstrap collision did not fail");
      assert (match collision.state with Rejected _ -> true | _ -> false);
      let cancelled = B.create () in
      let io =
        {
          Io.blocking with
          check =
            (fun () ->
              match cancelled.state with
              | B.Reported _ -> raise Libtmux_unix.Cancellation.Cancelled
              | _ -> ());
        }
      in
      (match start cancelled io "workspace-cancelled" with
      | _ -> failwith "startup cancellation did not propagate"
      | exception Libtmux_unix.Cancellation.Cancelled -> ());
      let hint =
        match cancelled.state with
        | B.Reported hint -> hint
        | _ -> failwith "lost uncertain creation receipt"
      in
      assert (hint.server_pid = Source.server_pid connection.source);
      let body =
        C.request connection "list-sessions" [ "-F"; "#{session_name}" ]
      in
      assert (String.split_on_char '\n' body |> List.mem "workspace-cancelled");
      print_endline
        "PASS bound startup, collision, retained cancellation, healthy daemon");
  print_endline "CLOSED"
