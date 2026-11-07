open Libtmux
module Io = Libtmux_unix__Runtime_io
module C = Libtmux_unix__Connection
module Engine = Libtmux_unix__Engine
module Linux = Libtmux_unix__Linux
module Rendered = Captured_text
module Streaming = Libtmux_unix__Streaming

let protect f =
  try Io.protect f
  with Eio.Io _ as exn -> Error (Error.Disconnected (Printexc.to_string exn))

module Terminal = struct
  let attach_current ?(binary = "tmux") ?(read_only = false)
      ?(update_environment = false) ?stdin ?stdout ?stderr ~process_mgr endpoint
      ~session =
    protect (fun () ->
        let module Terminal = Libtmux_unix__Terminal in
        let arguments =
          Terminal.arguments ~binary ~read_only ~update_environment endpoint
            session
        in
        Eio.Fiber.check ();
        Eio.Switch.run (fun sw ->
            let env =
              Eio.Process.environment process_mgr
              |> Eio.Process.Env.override
                   [ ("TMUX", None); ("TMUX_PANE", None) ]
            in
            let process =
              Eio.Process.spawn ~sw process_mgr ?stdin ?stdout ?stderr ~env
                arguments
            in
            Fun.protect
              ~finally:(fun () ->
                Eio.Cancel.protect (fun () ->
                    Eio.Process.signal process Sys.sigterm;
                    ignore (Eio.Process.await process)))
              (fun () ->
                match Eio.Process.await process with
                | `Exited code -> Terminal.exited code
                | `Signaled signal -> Terminal.signaled signal)))
end

let io ~sw ~process_mgr ~mono_clock =
  let io_failure exn = Io.fail (Error.Disconnected (Printexc.to_string exn)) in
  let spawn arguments =
    let closers = ref [] in
    let stop_child = ref None in
    let pipe () =
      let reader, writer = Eio_unix.pipe sw in
      closers :=
        (fun () -> Eio.Flow.close reader)
        :: (fun () -> Eio.Flow.close writer)
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
        Eio.Process.spawn ~sw process_mgr ~stdin ~stdout ~stderr ~env arguments
      in
      let stopped = ref false in
      let stop () =
        Eio.Cancel.protect (fun () ->
            if not !stopped then (
              stopped := true;
              Eio.Process.signal process Sys.sigterm;
              Fun.protect
                ~finally:(fun () -> ignore (Eio.Process.await process))
                (fun () -> List.iter (fun close -> close ()) !closers)))
      in
      stop_child := Some stop;
      Eio.Flow.close stdin;
      Eio.Flow.close stdout;
      Eio.Flow.close stderr;
      let descriptor flow =
        Eio_unix.Fd.use_exn "libtmux control pipe" (Eio_unix.Resource.fd flow)
          (fun fd ->
            Unix.set_nonblock fd;
            fd)
      in
      Io.
        {
          input = descriptor input;
          output = descriptor output;
          error = descriptor error;
          stop;
        }
    with exn -> (
      Eio.Cancel.protect (fun () ->
          match !stop_child with
          | Some stop -> stop ()
          | None -> List.iter (fun close -> close ()) !closers);
      match exn with Eio.Io _ -> io_failure exn | _ -> raise exn)
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
    Io.spawn;
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

module Operation = struct
  type 'a t = { inner : 'a Engine.operation; changed : Eio.Condition.t }

  type cleanup_receipt = Engine.cleanup_receipt = {
    cause : Error.t;
    owned_buffers : string list;
    created : Created.t list;
  }

  type 'a state = 'a Engine.state =
    | Queued
    | Not_started
    | Written
    | Acknowledged
    | Finished of ('a, Error.t) result
    | Outcome_unknown of cleanup_receipt

  let id op = Engine.id op.inner
  let inspect op = protect (fun () -> Engine.inspect op.inner)
  let cancel op = protect (fun () -> Engine.cancel op.inner)

  let await_stage op stage =
    protect (fun () ->
        C.owner op.inner.client.connection;
        let rec wait () =
          Eio.Fiber.check ();
          let state = Engine.inspect op.inner in
          match (state, stage) with
          | Queued, _ | Written, `Acknowledged ->
              Eio.Condition.await_no_mutex op.changed;
              wait ()
          | _ -> state
        in
        wait ())
end

module Subscription = struct
  type t = {
    inner : Streaming.subscription;
    changed : Eio.Condition.t;
    sleep : float -> unit;
  }

  let poll sub = protect (fun () -> Streaming.poll sub.inner)

  let close sub =
    protect (fun () -> Eio.Cancel.protect (fun () -> Streaming.close sub.inner))

  let next ?(timeout = 1.) sub =
    try
      protect (fun () ->
          C.owner sub.inner.manager.connection;
          if (not (Float.is_finite timeout)) || timeout <= 0. then
            Io.fail
              (Error.Invalid_input
                 "subscription timeout must be finite and positive");
          Eio.Fiber.first
            (fun () ->
              let rec wait () =
                Eio.Fiber.check ();
                match Streaming.poll sub.inner with
                | Some event -> Some event
                | None when not sub.inner.active -> None
                | None ->
                    Eio.Condition.await_no_mutex sub.changed;
                    wait ()
              in
              wait ())
            (fun () ->
              sub.sleep timeout;
              Io.fail Error.Deadline_exceeded))
    with Eio.Cancel.Cancelled _ as exn ->
      Eio.Cancel.protect (fun () -> Streaming.close sub.inner);
      raise exn

  let wait_for_bytes ?(timeout = 1.) sub ~text =
    Streaming.wait_for_bytes ~timeout sub.inner ~text ~next:(fun timeout ->
        next ~timeout sub)
end

module Client = struct
  type t = {
    engine : Engine.t;
    changed : Eio.Condition.t;
    streams : Streaming.t;
    pending_streams : Streaming.lane Queue.t;
    sleep : float -> unit;
    mutable contexts : Eio.Cancel.t list;
    mutable closing : bool;
    mutable release : Eio.Switch.hook;
  }

  exception Client_closed

  let close_exn t =
    C.owner t.engine.connection;
    if not t.closing then
      Eio.Cancel.protect (fun () ->
          t.closing <- true;
          List.iter
            (fun context -> Eio.Cancel.cancel context Client_closed)
            t.contexts;
          Streaming.close_all t.streams Output.Client_closed;
          Engine.close t.engine;
          Eio.Switch.remove_hook t.release;
          Eio.Condition.broadcast t.changed)

  let close t =
    protect (fun () ->
        close_exn t;
        Eio.Cancel.protect (fun () ->
            while t.contexts <> [] do
              Eio.Condition.await_no_mutex t.changed
            done))

  let source t = t.engine.connection.source
  let version t = t.engine.connection.version

  let worker ~sw t f =
    Eio.Fiber.fork_daemon ~sw (fun () ->
        (try
           Eio.Cancel.sub (fun context ->
               t.contexts <- context :: t.contexts;
               Fun.protect
                 ~finally:(fun () ->
                   t.contexts <- List.filter (( != ) context) t.contexts;
                   Eio.Condition.broadcast t.changed)
                 f)
         with
        | Eio.Cancel.Cancelled _ -> close_exn t
        | exn ->
            close_exn t;
            raise exn);
        `Stop_daemon)

  let idle_events t =
    let lane = t.engine.connection.lane in
    while not (Queue.is_empty lane.events) do
      match Queue.take lane.events with
      | C.P.Notification text when not (String.starts_with ~prefix:"%exit" text)
        ->
          ()
      | _ ->
          Io.fail
            (Error.Disconnected "unexpected data on idle primary connection")
    done

  let connect ?(binary = "tmux") ?timeout ~sw ~process_mgr ~mono_clock endpoint
      =
    protect (fun () ->
        let connection =
          C.connect ?timeout
            ~io:(io ~sw ~process_mgr ~mono_clock)
            ~binary endpoint
        in
        let changed = Eio.Condition.create () in
        let t =
          {
            engine =
              Engine.create
                ~changed:(fun () -> Eio.Condition.broadcast changed)
                connection;
            changed;
            streams =
              Streaming.create
                ~changed:(fun () -> Eio.Condition.broadcast changed)
                connection;
            pending_streams = Queue.create ();
            sleep = (fun seconds -> Eio.Time.Mono.sleep mono_clock seconds);
            contexts = [];
            closing = false;
            release = Eio.Switch.null_hook;
          }
        in
        t.streams.make_serial <-
          (fun () ->
            let mutex = Eio.Mutex.create () in
            {
              Streaming.run = (fun f -> Eio.Mutex.use_rw ~protect:false mutex f);
            });
        t.streams.started <-
          (fun lane ->
            Queue.add lane t.pending_streams;
            Eio.Condition.broadcast changed);
        t.release <-
          Eio.Switch.on_release_cancellable sw (fun () -> close_exn t);
        worker ~sw t (fun () ->
            Eio_unix.await_readable connection.pidfd;
            close_exn t);
        worker ~sw t (fun () ->
            let rec pump () =
              if not t.closing then (
                idle_events t;
                while not (Queue.is_empty t.pending_streams) do
                  let lane = Queue.take t.pending_streams in
                  if not lane.retired then
                    worker ~sw t (fun () ->
                        let rec read () =
                          if not lane.retired then (
                            Streaming.poll_lane lane;
                            if not lane.retired then (
                              Eio.Fiber.first
                                (fun () ->
                                  Eio_unix.await_readable
                                    lane.control.process.output)
                                (fun () ->
                                  Eio_unix.await_readable
                                    lane.control.process.error);
                              read ()))
                        in
                        match protect read with
                        | Ok () -> ()
                        | Error error ->
                            Streaming.retire lane (Output.Transport_error error))
                done;
                match Engine.take t.engine with
                | Some (Engine.Pack op as job) ->
                    (match Command.view op.command with
                    | Wait_for _ -> worker ~sw t (fun () -> Engine.run job)
                    | _ -> Engine.run job);
                    if connection.closed then close_exn t else pump ()
                | None ->
                    Eio.Fiber.first
                      (fun () -> Eio.Condition.await_no_mutex changed)
                      (fun () ->
                        Eio_unix.await_readable connection.lane.process.output;
                        let bytes =
                          Io.read connection.lane.io connection.lane.process
                            ~pidfd:(Some connection.pidfd)
                            ~deadline:(Linux.now () +. connection.timeout)
                        in
                        let events =
                          Io.protocol
                            (C.P.Framer.feed connection.lane.framer bytes)
                        in
                        List.iter
                          (fun event -> Queue.add event connection.lane.events)
                          events);
                    pump ())
            in
            match protect pump with Ok () -> () | Error _ -> close_exn t);
        t)

  let submit t command =
    protect (fun () ->
        let inner = Engine.submit t.engine command in
        Operation.{ inner; changed = t.changed })

  let await op =
    try
      protect (fun () ->
          C.owner op.Operation.inner.client.connection;
          let rec wait () =
            Eio.Fiber.check ();
            match Engine.result op.Operation.inner with
            | Some result -> Io.get result
            | None ->
                Eio.Condition.await_no_mutex op.changed;
                wait ()
          in
          wait ())
    with Eio.Cancel.Cancelled _ as exn ->
      Engine.cancel op.inner;
      raise exn

  let run t command = Result.bind (submit t command) await

  let subscribe ?session ?capacity_bytes ?capacity_events t pane =
    protect (fun () ->
        let inner =
          Streaming.subscribe ?session ?capacity_bytes ?capacity_events
            t.streams pane
        in
        Subscription.{ inner; changed = t.changed; sleep = t.sleep })

  let capture t = run t (Operations.capture ())

  include Generated_operations.Make (struct
    type nonrec t = t

    let run = run
  end)

  let capture_text ?scratch_dir t pane ~start ~end_ =
    run t (Operations.capture_text ?scratch_dir pane ~start ~end_)

  let wait_for_text ?(timeout = 1.) ?scratch_dir t pane ~text =
    protect (fun () ->
        Libtmux_unix__Observation_wait.rendered ~connection:t.engine.connection
          ~capture:(fun () -> capture t)
          ~capture_text:(fun pane ->
            capture_text ?scratch_dir t pane ~start:0
              ~end_:(Pane.height pane - 1))
          ~subscribe:(subscribe t)
          ~next:(fun timeout sub -> Subscription.next ~timeout sub)
          ~poll:Subscription.poll ~close:Subscription.close ~timeout pane ~text)
end
