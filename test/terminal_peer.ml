open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

exception Stop_terminal

let () =
  let binary = if Sys.argv.(6) = "invalid" then "" else Sys.argv.(1)
  and endpoint = Endpoint.socket_path Sys.argv.(2)
  and backend = Sys.argv.(3)
  and terminal = Sys.argv.(4)
  and session = get (Session.Id.of_string Sys.argv.(5))
  and mode = Sys.argv.(6) in
  let check_result = function
    | Error (Error.Command_failed _) when mode = "missing" -> ()
    | Error (Error.Invalid_input _) when mode = "invalid" -> ()
    | value when mode = "missing" || mode = "invalid" ->
        ignore (get value);
        failwith "invalid attachment succeeded"
    | value -> get value
  in
  if backend = "unix" then
    let tty = Unix.openfile terminal [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close tty)
      (fun () ->
        let attach ?cancel () =
          Libtmux_unix.Terminal.attach_current ?cancel ~binary ~read_only:true
            ~update_environment:(mode = "update") ~stdin:tty ~stdout:tty
            ~stderr:tty endpoint ~session
        in
        if mode = "cancel" || mode = "pre_cancel" then
          Libtmux_unix.Cancellation.with_ (fun token ->
              let canceller =
                if mode = "pre_cancel" then (
                  Libtmux_unix.Cancellation.cancel token;
                  None)
                else
                  Some
                    (Domain.spawn (fun () ->
                         assert (read_line () = "CANCEL");
                         Libtmux_unix.Cancellation.cancel token))
              in
              Fun.protect
                ~finally:(fun () -> Option.iter Domain.join canceller)
                (fun () ->
                  match attach ~cancel:token () with
                  | _ -> failwith "cancelled attachment returned"
                  | exception Libtmux_unix.Cancellation.Cancelled -> ()))
        else check_result (attach ());
        assert (Unix.isatty tty))
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let tty =
              Eio.Path.open_out ~sw ~create:`Never
                Eio.Path.(Eio.Stdenv.fs env / terminal)
            in
            let attach () =
              Libtmux_eio.Terminal.attach_current ~binary ~read_only:true
                ~update_environment:(mode = "update") ~stdin:tty ~stdout:tty
                ~stderr:tty
                ~process_mgr:(Eio.Stdenv.process_mgr env)
                endpoint ~session
            in
            if mode = "cancel" || mode = "pre_cancel" then (
              let context, resolve = Eio.Promise.create () in
              let finished =
                Eio.Fiber.fork_promise ~sw (fun () ->
                    Eio.Cancel.sub (fun scope ->
                        Eio.Promise.resolve resolve scope;
                        if mode = "pre_cancel" then
                          Eio.Cancel.cancel scope Stop_terminal;
                        match attach () with
                        | _ -> failwith "cancelled attachment returned"
                        | exception Eio.Cancel.Cancelled Stop_terminal -> ()))
              in
              let scope = Eio.Promise.await context in
              if mode = "cancel" then (
                let input =
                  Eio.Buf_read.of_flow ~max_size:1024 (Eio.Stdenv.stdin env)
                in
                assert (Eio.Buf_read.line input = "CANCEL");
                Eio.Cancel.cancel scope Stop_terminal);
              Eio.Promise.await_exn finished)
            else check_result (attach ());
            Eio_unix.Fd.use_exn "retained terminal"
              (Option.get (Eio_unix.Resource.fd_opt tty))
              (fun fd -> assert (Unix.isatty fd))));
  print_endline "PASS terminal attachment and reaping"
