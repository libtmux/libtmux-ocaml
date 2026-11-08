open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

exception Stop_setup

let failed = function
  | Error (Error.Malformed_data "shutdown fixture") -> ()
  | Error error ->
      failwith (Format.asprintf "lost setup error: %a" Error.pp error)
  | Ok _ -> failwith "malformed setup succeeded"

let () =
  let binary = Sys.argv.(1)
  and endpoint = Endpoint.socket_path Sys.argv.(2)
  and backend = Sys.argv.(3)
  and mode = Sys.argv.(4) in
  if backend = "unix" then (
    (match mode with
    | "close" ->
        let client = get (Libtmux_unix.Client.connect ~binary endpoint) in
        print_endline "READY";
        assert (read_line () = "GO");
        get (Libtmux_unix.Client.close client)
    | "failed" -> failed (Libtmux_unix.Client.connect ~binary endpoint)
    | "terminal" ->
        let tty =
          Unix.openfile Sys.argv.(5) [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0
        in
        Fun.protect
          ~finally:(fun () -> Unix.close tty)
          (fun () ->
            Libtmux_unix.Cancellation.with_ (fun token ->
                let canceller =
                  Domain.spawn (fun () ->
                      assert (read_line () = "GO");
                      Libtmux_unix.Cancellation.cancel token)
                in
                Fun.protect
                  ~finally:(fun () -> Domain.join canceller)
                  (fun () ->
                    match
                      Libtmux_unix.Terminal.attach_current ~binary ~cancel:token
                        ~stdin:tty ~stdout:tty ~stderr:tty endpoint
                        ~session:(get (Session.Id.of_string "$0"))
                    with
                    | _ -> failwith "terminal cancellation was lost"
                    | exception Libtmux_unix.Cancellation.Cancelled -> ())))
    | _ -> failwith "unknown blocking shutdown mode");
    print_endline "DONE";
    assert (read_line () = "EXIT"))
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let input =
              Eio.Buf_read.of_flow ~max_size:1024 (Eio.Stdenv.stdin env)
            in
            let read () = Eio.Buf_read.line input in
            let connect () =
              Libtmux_eio.Client.connect ~binary ~sw
                ~process_mgr:(Eio.Stdenv.process_mgr env)
                ~mono_clock:(Eio.Stdenv.mono_clock env)
                endpoint
            in
            (match mode with
            | "close" | "close-join" ->
                let client = get (connect ()) in
                print_endline "READY";
                let message = read () in
                let helper =
                  if mode = "close-join" then
                    Scanf.sscanf message "GO %d" Fun.id
                  else (
                    assert (message = "GO");
                    0)
                in
                let closing =
                  Eio.Fiber.fork_promise ~sw (fun () ->
                      get (Libtmux_eio.Client.close client))
                in
                assert (not (Eio.Promise.is_resolved closing));
                print_endline "YIELDED";
                if mode = "close-join" then (
                  get (Libtmux_eio.Client.close client);
                  if Sys.file_exists (Printf.sprintf "/proc/%d" helper) then
                    failwith "second close returned before helper was reaped");
                Eio.Promise.await_exn closing
            | "failed" -> failed (connect ())
            | "terminal" | "cancel-setup" ->
                let context, publish = Eio.Promise.create () in
                let finished =
                  Eio.Fiber.fork_promise ~sw (fun () ->
                      Eio.Cancel.sub (fun scope ->
                          Eio.Promise.resolve publish scope;
                          let operation () =
                            if mode = "cancel-setup" then
                              ignore (get (connect ()))
                            else
                              let tty =
                                Eio.Path.open_out ~sw ~create:`Never
                                  Eio.Path.(Eio.Stdenv.fs env / Sys.argv.(5))
                              in
                              get
                                (Libtmux_eio.Terminal.attach_current ~binary
                                   ~process_mgr:(Eio.Stdenv.process_mgr env)
                                   ~stdin:tty ~stdout:tty ~stderr:tty endpoint
                                   ~session:(get (Session.Id.of_string "$0")))
                          in
                          match operation () with
                          | () -> failwith "native cancellation was lost"
                          | exception Eio.Cancel.Cancelled Stop_setup -> ()))
                in
                let scope = Eio.Promise.await context in
                assert (read () = "GO");
                Eio.Cancel.cancel scope Stop_setup;
                Eio.Promise.await_exn finished
            | _ -> failwith "unknown Eio shutdown mode");
            print_endline "DONE";
            (* Keep the owning switch alive so its fallback cleanup cannot
               disguise a child left behind by the library. *)
            assert (read () = "EXIT")))
