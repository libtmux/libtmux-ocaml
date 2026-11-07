open Libtmux
module Client = Libtmux_eio.Client
module Subscription = Libtmux_eio.Subscription

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

(* docs:begin stream-and-wait *)
let send_and_observe client pane ~text =
  let subscription = get (Client.subscribe client pane) in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> get (Subscription.close subscription)))
    (fun () ->
      let cursor, () =
        Eio.Fiber.pair
          (fun () ->
            match
              Subscription.wait_for_bytes ~timeout:0.5 subscription ~text
            with
            | Ok cursor -> cursor
            | Error (Output.Failure error) ->
                failwith (Format.asprintf "%a" Error.pp error)
            | Error (Output.Ended reason) ->
                failwith (Format.asprintf "%a" Output.reason_pp reason))
          (fun () ->
            get (Client.send_text client (Pane.target pane) ~text);
            get (Client.send_keys client (Pane.target pane) [ Key.Enter ]))
      in
      let rendered =
        get (Client.wait_for_text ~timeout:0.5 client pane ~text)
      in
      (cursor, rendered))
(* docs:end stream-and-wait *)

let () =
  if Array.length Sys.argv <> 5 then (
    prerr_endline "usage: native_watch TMUX_BINARY SOCKET_PATH PANE_ID TEXT";
    exit 2);
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let client =
            get
              (Client.connect ~sw ~binary:Sys.argv.(1)
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          Fun.protect
            ~finally:(fun () ->
              Eio.Cancel.protect (fun () -> get (Client.close client)))
            (fun () ->
              let snapshot = get (Client.capture client) in
              let id = get (Pane.Id.of_string Sys.argv.(3)) in
              let pane =
                match Snapshot.find_pane snapshot id with
                | Some pane -> pane
                | None -> failwith "requested pane is absent from the capture"
              in
              let cursor, rendered =
                send_and_observe client pane ~text:Sys.argv.(4)
              in
              Printf.printf "future_match_offset=%Ld\nrendered_pane=%s\n"
                cursor.offset
                (Pane.Id.to_string rendered.pane))))
