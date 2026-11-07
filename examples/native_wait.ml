open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let () =
  if Array.length Sys.argv <> 4 then (
    prerr_endline "usage: native_wait TMUX_BINARY SOCKET_PATH TEXT";
    exit 2);
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let module C = Libtmux_eio.Client in
          let client =
            get
              (C.connect ~sw ~binary:Sys.argv.(1)
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          Fun.protect
            ~finally:(fun () -> ignore (get (C.close client)))
            (fun () ->
              let snapshot = get (C.capture client) in
              let pane =
                match
                  Query.exactly_one (Iarray.to_seq (Snapshot.panes snapshot))
                with
                | Ok pane -> pane
                | Error error ->
                    failwith (Format.asprintf "%a" Cardinality.pp_error error)
              in
              ignore
                (get
                   (C.wait_for_text ~timeout:0.5 client pane ~text:Sys.argv.(3)));
              print_endline (Pane.Id.to_string (Pane.id pane)))))
