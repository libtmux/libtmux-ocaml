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

let daemon_exit ~paused client =
  let module C = Libtmux_eio.Client in
  let module O = Libtmux_eio.Operation in
  let pids snapshot =
    Snapshot.clients snapshot |> Iarray.to_seq
    |> Seq.map Client_observation.pid
    |> List.of_seq
  in
  let stop_new_helper before =
    match
      pids (get (C.capture client))
      |> List.filter (fun pid -> not (List.mem pid before))
    with
    | [ pid ] -> Unix.kill pid Sys.sigstop
    | _ -> failwith "expected one newly owned helper"
  in
  if paused then (
    let snapshot = get (C.capture client) in
    let before = pids snapshot in
    ignore (get (C.subscribe client (Iarray.get (Snapshot.panes snapshot) 0)));
    stop_new_helper before);
  let before_wait = pids (get (C.capture client)) in
  let operation = get (C.submit client (Operations.wait_for "daemon-exit")) in
  assert (get (O.await_stage operation `Acknowledged) = O.Acknowledged);
  stop_new_helper before_wait;
  assert (get (O.inspect operation) = O.Acknowledged);
  print_endline "READY_EXIT";
  (match C.await operation with
  | Error (Error.Outcome_unknown _) -> ()
  | Ok () -> failwith "wait completed before daemon retirement"
  | Error error ->
      failwith
        (Format.asprintf "daemon exit returned a known error: %a" Error.pp error));
  let check () =
    match get (O.inspect operation) with
    | O.Outcome_unknown { cause = Error.Disconnected _; _ } -> ()
    | O.Outcome_unknown receipt ->
        failwith
          (Format.asprintf "daemon exit retained the wrong cause: %a" Error.pp
             receipt.cause)
    | _ -> failwith "daemon exit lost the retained outcome"
  in
  check ();
  get (C.close client);
  check ();
  print_endline "RETAIN daemon disconnection"

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
                if String.starts_with ~prefix:"eio-daemon-exit" Sys.argv.(3)
                then
                  daemon_exit
                    ~paused:(Sys.argv.(3) = "eio-daemon-exit-paused")
                    client
                else
                  exercise
                    ~capture:(fun () -> C.capture client)
                    ~subscribe:(C.subscribe client)
                    ~close_subscription:Libtmux_eio.Subscription.close
                    ~line:(fun () -> Eio.Buf_read.line input))))
