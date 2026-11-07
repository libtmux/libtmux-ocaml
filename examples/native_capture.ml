open Libtmux
module Client = Libtmux_eio.Client

let capture ~sw ~process_mgr ~mono_clock ~binary endpoint =
  let ( let* ) = Result.bind in
  let* client = Client.connect ~sw ~process_mgr ~mono_clock ~binary endpoint in
  let* snapshot = Client.capture client in
  let* () = Client.close client in
  Ok snapshot

let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: native_capture TMUX_BINARY SOCKET_PATH";
    exit 64);
  let endpoint = Endpoint.socket_path Sys.argv.(2) in
  let result =
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            capture ~sw ~binary:Sys.argv.(1)
              ~process_mgr:(Eio.Stdenv.process_mgr env)
              ~mono_clock:(Eio.Stdenv.mono_clock env)
              endpoint))
  in
  match result with
  | Ok snapshot ->
      Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
      |> Seq.iter (fun pane -> print_endline (Pane.Id.to_string (Pane.id pane)))
  | Error error ->
      Format.eprintf "%a@." Error.pp error;
      exit 1
