open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let exercise ~capture ~subscribe ~close_subscription ~line =
  let pane = Iarray.get (Snapshot.panes (get (capture ()))) 0 in
  let sub = get (subscribe pane) in
  get (close_subscription sub);
  print_endline "READY";
  assert (line () = "continue");
  (match subscribe pane with
  | Error Error.Stale_target -> ()
  | _ -> failwith "replacement admitted a bound subscription");
  assert (capture () = Error Error.Closed);
  print_endline "REJECT replacement"

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  if Sys.argv.(3) = "unix" then
    let module C = Libtmux_unix.Client in
    let client = get (C.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (C.close client)))
      (fun () ->
        exercise
          ~capture:(fun () -> C.capture client)
          ~subscribe:(C.subscribe client)
          ~close_subscription:Libtmux_unix.Subscription.close ~line:read_line)
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let module C = Libtmux_eio.Client in
            let client =
              get
                (C.connect ~sw ~binary
                   ~process_mgr:(Eio.Stdenv.process_mgr env)
                   ~mono_clock:(Eio.Stdenv.mono_clock env)
                   endpoint)
            in
            let input =
              Eio.Buf_read.of_flow ~max_size:1024 (Eio.Stdenv.stdin env)
            in
            Fun.protect
              ~finally:(fun () -> ignore (get (C.close client)))
              (fun () ->
                exercise
                  ~capture:(fun () -> C.capture client)
                  ~subscribe:(C.subscribe client)
                  ~close_subscription:Libtmux_eio.Subscription.close
                  ~line:(fun () -> Eio.Buf_read.line input))))
