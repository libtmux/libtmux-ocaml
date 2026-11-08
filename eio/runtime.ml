open Libtmux
module Cleanup_internal = Libtmux_unix__Cleanup
module Io = Libtmux_unix__Runtime_io
module Linux = Libtmux_unix__Linux

exception Process_closed

let finalizer () =
  let started = ref false in
  let finished, publish = Eio.Promise.create () in
  fun f ->
    Eio.Cancel.protect (fun () ->
        if not !started then (
          started := true;
          let result =
            try Ok (f ())
            with exn -> Error (exn, Printexc.get_raw_backtrace ())
          in
          Eio.Promise.resolve publish result);
        Cleanup_internal.get (Eio.Promise.await finished))

let create ~cleanup ~sw ~process_mgr ~mono_clock =
  Cleanup_internal.check cleanup;
  let io_failure exn = Io.fail (Error.Disconnected (Printexc.to_string exn)) in
  let spawn arguments =
    let closers = ref [] in
    let stop_child = ref None in
    let pipe () =
      let reader, writer = Eio_unix.pipe sw in
      closers :=
        (fun () ->
          Cleanup_internal.step cleanup Close_pipe (fun () ->
              Eio.Flow.close reader))
        :: (fun () ->
          Cleanup_internal.step cleanup Close_pipe (fun () ->
              Eio.Flow.close writer))
        :: !closers;
      (reader, writer)
    in
    try
      let stdin, input = pipe ()
      and output, stdout = pipe ()
      and error, stderr = pipe () in
      let env =
        Eio.Process.environment process_mgr
        |> Eio.Process.Env.override [ ("TMUX", None); ("TMUX_PANE", None) ]
      in
      let process =
        Owned_process.spawn ~cleanup ~sw ~process_mgr ~stdin ~stdout ~stderr
          ~env arguments
      in
      let stopped = ref false in
      let waiters = ref [] and changed = Eio.Condition.create () in
      let finished, publish = Eio.Promise.create () in
      let release = ref Eio.Switch.null_hook in
      let stop () =
        Eio.Cancel.protect (fun () ->
            if not !stopped then (
              stopped := true;
              let result =
                try
                  Cleanup_internal.run
                    (List.map
                       (fun scope () ->
                         Cleanup_internal.step cleanup Cancel_workers (fun () ->
                             Eio.Cancel.cancel scope Process_closed))
                       !waiters
                    @ [
                        (fun () ->
                          while !waiters <> [] do
                            Eio.Condition.await_no_mutex changed
                          done);
                      ]
                    @ !closers
                    @ [
                        (fun () -> process.stop ());
                        (fun () ->
                          Cleanup_internal.step cleanup Release_hook (fun () ->
                              Eio.Switch.remove_hook !release));
                      ]);
                  Ok ()
                with exn -> Error (exn, Printexc.get_raw_backtrace ())
              in
              Eio.Promise.resolve publish result);
            Cleanup_internal.get (Eio.Promise.await finished))
      in
      stop_child := Some stop;
      release := Eio.Switch.on_release_cancellable sw stop;
      Eio.Flow.close stdin;
      Eio.Flow.close stdout;
      Eio.Flow.close stderr;
      let descriptor flow =
        match Eio_unix.Fd.remove (Eio_unix.Resource.fd flow) with
        | None -> Io.fail Error.Closed
        | Some fd ->
            (* The engine owns this pipe end after transfer, including setup
               failure and switch release. No borrowed raw FD escapes. *)
            closers :=
              (fun () -> Io.cleanup_fd cleanup Close_pipe fd) :: !closers;
            Unix.set_nonblock fd;
            fd
      in
      let await f =
        if !stopped then Io.fail Error.Closed;
        try
          Eio.Cancel.sub (fun scope ->
              waiters := scope :: !waiters;
              Fun.protect
                ~finally:(fun () ->
                  waiters := List.filter (( != ) scope) !waiters;
                  Eio.Condition.broadcast changed)
                f)
        with Eio.Cancel.Cancelled Process_closed -> Io.fail Error.Closed
      in
      Io.
        {
          input = descriptor input;
          output = descriptor output;
          error = descriptor error;
          is_open = (fun () -> not !stopped);
          await;
          stop;
        }
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      Cleanup_internal.protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () ->
              match !stop_child with
              | Some stop -> stop ()
              | None -> Cleanup_internal.run !closers))
        (fun () ->
          match exn with
          | Eio.Io _ -> io_failure exn
          | _ -> Printexc.raise_with_backtrace exn bt)
  in
  let wait ~read ~write ~deadline =
    try
      Eio.Fiber.any
        ((fun () ->
           let remaining = deadline -. Linux.now () in
           if remaining > 0. then Eio.Time.Mono.sleep mono_clock remaining;
           Io.fail Error.Deadline_exceeded)
         :: List.map (fun fd () -> Eio_unix.await_readable fd) read
        @ List.map (fun fd () -> Eio_unix.await_writable fd) write)
    with Eio.Io _ as exn -> io_failure exn
  in
  {
    Io.cleanup;
    spawn;
    finalizer;
    wait;
    check =
      (fun () ->
        Eio.Fiber.check ();
        Eio.Fiber.yield ());
    file_io =
      (fun f ->
        Eio.Cancel.protect (fun () ->
            Eio_unix.run_in_systhread ~label:"libtmux scratch I/O" f));
  }
