(* Outer: real owned child pipes and deliberate descriptor-number reuse. *)
open Libtmux
module Io = Libtmux_unix__Runtime_io
module Linux = Libtmux_unix__Linux

exception Cancel_read

let pending_read ~sw (io : Io.t) cancel =
  let process = io.spawn [ "/bin/cat" ] in
  let ready, publish = Eio.Promise.create () in
  let context = ref None and awaiting = ref false in
  let io =
    {
      io with
      wait =
        (fun ~read ~write ~deadline ->
          awaiting := true;
          if not (Eio.Promise.is_resolved ready) then
            Eio.Promise.resolve publish ();
          Fun.protect
            ~finally:(fun () -> awaiting := false)
            (fun () -> io.wait ~read ~write ~deadline));
    }
  in
  Fun.protect ~finally:process.stop (fun () ->
      let reading =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Eio.Cancel.sub (fun scope ->
                context := Some scope;
                Io.protect (fun () ->
                    Io.read io process ~pidfd:None
                      ~deadline:(Linux.now () +. 0.5))))
      in
      Eio.Promise.await ready;
      if cancel then Eio.Cancel.cancel (Option.get !context) Cancel_read
      else process.stop ();
      let result = Eio.Promise.await reading in
      (match (cancel, result) with
      | false, Ok (Error Error.Closed)
      | true, Error (Eio.Cancel.Cancelled Cancel_read) ->
          ()
      | _ -> failwith "pending read lost closure or native cancellation");
      if !awaiting then failwith "descriptor readiness wait survived teardown")

let reused_pipe (io : Io.t) operation =
  let process = io.spawn [ "/bin/cat" ] in
  let reader, writer = Unix.pipe ~cloexec:true () in
  let replaced = ref false in
  let old, replacement =
    if operation = "write" then (process.input, writer)
    else (process.output, reader)
  in
  Fun.protect
    ~finally:(fun () ->
      process.stop ();
      if !replaced then Unix.close old;
      Unix.close reader;
      Unix.close writer)
    (fun () ->
      Unix.set_nonblock reader;
      if operation = "read" then
        ignore (Unix.write_substring writer "sentinel" 0 8);
      let io =
        {
          io with
          check =
            (fun () ->
              if not !replaced then (
                process.stop ();
                Unix.dup2 ~cloexec:true replacement old;
                replaced := true));
        }
      in
      let deadline = Linux.now () +. 0.5 in
      let result =
        Io.protect (fun () ->
            if operation = "write" then
              Io.write io process ~pidfd:None ~deadline "late"
            else ignore (Io.read io process ~pidfd:None ~deadline))
      in
      let buffer = Bytes.create 16 in
      let received =
        try Unix.read reader buffer 0 16
        with Unix.Unix_error (Unix.EAGAIN, _, _) -> 0
      in
      let expected = if operation = "write" then 0 else 8 in
      if received <> expected then
        failwith (operation ^ " touched a replacement descriptor after close");
      if result <> Error Error.Closed then
        failwith (operation ^ " did not reject the stopped process"))

let () =
  let failures = ref [] in
  let check label f =
    try f ()
    with Failure message -> failures := (label ^ ": " ^ message) :: !failures
  in
  List.iter
    (fun operation ->
      check "Unix" (fun () -> reused_pipe (Io.blocking ()) operation))
    [ "write"; "read" ];
  Eio_main.run (fun env ->
      Printf.printf "Eio backend: %s\n%!" (Eio.Stdenv.backend_id env);
      let make sw =
        Libtmux_eio__Runtime.create ~sw
          ~cleanup:(Libtmux_unix.Cleanup.create ())
          ~process_mgr:(Eio.Stdenv.process_mgr env)
          ~mono_clock:(Eio.Stdenv.mono_clock env)
      in
      Eio.Switch.run (fun sw ->
          List.iter
            (fun operation ->
              check "Eio" (fun () -> reused_pipe (make sw) operation))
            [ "write"; "read" ];
          List.iter
            (fun cancel ->
              check "Eio pending read" (fun () ->
                  pending_read ~sw (make sw) cancel))
            [ false; true ];
          check "Eio concurrent helper stop" (fun () ->
              let io = make sw in
              let process =
                io.spawn
                  [
                    "python3";
                    "-c";
                    "import \
                     os,signal;signal.signal(signal.SIGTERM,signal.SIG_IGN);os.write(1,str(os.getpid()).encode());signal.pause()";
                  ]
              in
              let pid =
                Io.read io process ~pidfd:None ~deadline:(Linux.now () +. 0.5)
                |> int_of_string
              in
              let first = Eio.Fiber.fork_promise ~sw process.stop in
              process.stop ();
              if Sys.file_exists (Printf.sprintf "/proc/%d" pid) then
                failwith "second stop returned before helper was reaped";
              Eio.Promise.await_exn first));
      check "Eio switch teardown" (fun () ->
          let process =
            Eio.Switch.run (fun sw -> (make sw).spawn [ "/bin/cat" ])
          in
          if process.is_open () then
            failwith "process still admits I/O after switch release"));
  if !failures <> [] then failwith (String.concat "; " (List.rev !failures));
  print_endline "PASS closed process I/O leaves reused descriptors untouched"
