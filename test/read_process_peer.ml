open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let command = Operations.capture_environment Environment.Global

let fault mode ~read ~capture ~line =
  print_endline "READY";
  assert (line () = "CONTINUE");
  let result, cause = read () in
  (match (mode, result, cause) with
  | "replace", Error (Error.Outcome_unknown _), Some Error.Stale_target ->
      assert (capture () = Error Error.Closed)
  | ("truncated" | "malformed"), Error (Error.Malformed_data _), None ->
      ignore (get (capture ()))
  | "oversized", Error (Error.Capacity _), None -> ignore (get (capture ()))
  | "error", Error (Error.Command_failed _), None -> ignore (get (capture ()))
  | _ ->
      failwith
        (Format.asprintf "unexpected fault result: %s"
           (match result with
           | Ok _ -> "success"
           | Error error -> Format.asprintf "%a" Error.pp error)));
  print_endline "REJECTED"

exception Cancel_waiter

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  let mode = Sys.argv.(4) in
  if Sys.argv.(3) = "unix" then (
    let module C = Libtmux_unix.Client in
    let module O = Libtmux_unix.Operation in
    let module K = Libtmux_unix.Cancellation in
    let before = Array.length (Sys.readdir "/proc/self/fd") in
    let client = get (C.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (C.close client)))
      (fun () ->
        if mode = "cancel" then (
          let op = get (C.submit client command) in
          K.with_ (fun token ->
              let worker =
                Domain.spawn (fun () ->
                    assert (read_line () = "CANCEL");
                    K.cancel token;
                    print_endline "REQUESTED")
              in
              Fun.protect
                ~finally:(fun () -> Domain.join worker)
                (fun () ->
                  match C.await ~cancel:token op with
                  | _ -> failwith "cancelled read returned a value"
                  | exception K.Cancelled -> ()));
          ignore (get (C.await op));
          assert (
            match get (O.inspect op) with Finished (Ok _) -> true | _ -> false);
          print_endline "DRAINED")
        else
          fault mode ~line:read_line
            ~capture:(fun () -> C.capture client)
            ~read:(fun () ->
              let op = get (C.submit client command) in
              let result = C.await op in
              let cause =
                match get (O.inspect op) with
                | Outcome_unknown receipt -> Some receipt.cause
                | _ -> None
              in
              (result, cause)));
    assert (Array.length (Sys.readdir "/proc/self/fd") = before))
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let module C = Libtmux_eio.Client in
            let module O = Libtmux_eio.Operation in
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
            let line () = Eio.Buf_read.line input in
            Fun.protect
              ~finally:(fun () -> ignore (get (C.close client)))
              (fun () ->
                if mode = "cancel" then (
                  let op = get (C.submit client command) in
                  let context, context_ready = Eio.Promise.create () in
                  let cancelled, cancellation_done = Eio.Promise.create () in
                  Eio.Fiber.fork ~sw (fun () ->
                      Eio.Cancel.sub (fun scope ->
                          Eio.Promise.resolve context_ready scope;
                          try
                            ignore (get (C.await op));
                            failwith "read finished before barrier"
                          with Eio.Cancel.Cancelled Cancel_waiter ->
                            Eio.Promise.resolve cancellation_done ()));
                  let scope = Eio.Promise.await context in
                  assert (line () = "CANCEL");
                  Eio.Cancel.cancel scope Cancel_waiter;
                  Eio.Promise.await cancelled;
                  print_endline "CANCELLED";
                  ignore (get (C.await op));
                  assert (
                    match get (O.inspect op) with
                    | Finished (Ok _) -> true
                    | _ -> false);
                  print_endline "DRAINED")
                else
                  fault mode ~line
                    ~capture:(fun () -> C.capture client)
                    ~read:(fun () ->
                      let op = get (C.submit client command) in
                      let result = C.await op in
                      let cause =
                        match get (O.inspect op) with
                        | Outcome_unknown receipt -> Some receipt.cause
                        | _ -> None
                      in
                      (result, cause)))))
