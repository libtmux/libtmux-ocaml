module Cleanup = Libtmux_unix__Cleanup
module Io = Libtmux_unix__Runtime_io

type t = { await : unit -> Eio.Process.exit_status; stop : unit -> unit }

let terminate cleanup process =
  Io.shutdown ~cleanup
    ~exited:(fun () ->
      Eio.Fiber.first
        (fun () ->
          ignore (Eio.Process.await process);
          true)
        (fun () -> false))
    ~signal:(Eio.Process.signal process)
    ~await:(fun () -> ignore (Eio.Process.await process))
    ~await_grace:(fun seconds ->
      Eio.Fiber.first
        (fun () ->
          ignore (Eio.Process.await process);
          true)
        (fun () ->
          Eio_unix.sleep seconds;
          false))

let spawn ~cleanup ~sw ~process_mgr ?stdin ?stdout ?stderr ~env arguments =
  let ready, publish_ready = Eio.Promise.create () in
  let finished, publish_finished = Eio.Promise.create () in
  let stopping, request_stop = Eio.Promise.create () in
  let request () =
    if not (Eio.Promise.is_resolved stopping) then
      Eio.Promise.resolve request_stop ()
  in
  let stop () =
    Eio.Cancel.protect (fun () ->
        request ();
        Cleanup.get (Eio.Promise.await finished))
  in
  Eio.Switch.check sw;
  (* The watcher stays cancellable. The owner keeps its process switch and
     reaper alive until TERM/grace/KILL/reap finishes, even during cancellation
     of the application's switch. Neither waits for that switch's hooks. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
      (try ignore (Eio.Promise.await finished)
       with Eio.Cancel.Cancelled _ -> request ());
      `Stop_daemon);
  Eio.Switch.check sw;
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio.Cancel.protect (fun () ->
          let result =
            try
              Eio.Switch.run (fun process_switch ->
                  let process =
                    Eio.Process.spawn ~sw:process_switch process_mgr ?stdin
                      ?stdout ?stderr ~env arguments
                  in
                  Eio.Promise.resolve publish_ready (Ok process);
                  Eio.Promise.await stopping;
                  terminate cleanup process);
              Ok ()
            with exn -> Error (exn, Printexc.get_raw_backtrace ())
          in
          Eio.Promise.resolve publish_finished result;
          if not (Eio.Promise.is_resolved ready) then
            match result with
            | Error failure -> Eio.Promise.resolve publish_ready (Error failure)
            | Ok () -> assert false);
      `Stop_daemon);
  try
    let process = Cleanup.get (Eio.Promise.await ready) in
    { await = (fun () -> Eio.Process.await process); stop }
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    Cleanup.protect ~finally:stop (fun () ->
        Printexc.raise_with_backtrace exn bt)
