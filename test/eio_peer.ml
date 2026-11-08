open Libtmux
module C = Libtmux_eio.Client
module O = Libtmux_eio.Operation

let get = function
  | Ok value -> value
  | Error e -> failwith (Format.asprintf "%a" Error.pp e)

exception Stop_waiting
exception Cleanup_failed

let cancel_wait op =
  let cancelled = ref false in
  (try
     Eio.Cancel.sub (fun context ->
         Eio.Cancel.cancel context Stop_waiting;
         ignore (C.await op))
   with Eio.Cancel.Cancelled Stop_waiting -> cancelled := true);
  assert !cancelled

let overlapping_connection_close ~sw ~process_mgr ~mono_clock ~binary endpoint =
  let module Connection = Libtmux_unix__Connection in
  List.iter
    (fun fail_cleanup ->
      let io =
        Libtmux_eio__Runtime.create ~sw ~process_mgr ~mono_clock
          ~cleanup:(Libtmux_unix.Cleanup.create ())
      in
      let connection = Connection.connect ~io ~binary endpoint in
      let entered, publish = Eio.Promise.create () in
      let release, resume = Eio.Promise.create () in
      connection.on_close <-
        (fun () ->
          Eio.Promise.resolve publish ();
          Eio.Promise.await release;
          if fail_cleanup then raise Exit);
      let close () =
        Eio.Cancel.protect (fun () -> Connection.close connection)
      in
      let first = Eio.Fiber.fork_promise ~sw close in
      Eio.Promise.await entered;
      let second = Eio.Fiber.fork_promise ~sw close in
      let returned_early = Eio.Promise.is_resolved second in
      Eio.Promise.resolve resume ();
      let first_result = Eio.Promise.await first
      and second_result = Eio.Promise.await second in
      if returned_early then
        failwith "overlapping connection close returned early";
      (match (fail_cleanup, first_result, second_result) with
      | false, Ok (), Ok () | true, Error Exit, Error Exit -> ()
      | _ -> failwith "connection close lost the retained cleanup result");
      match (fail_cleanup, close ()) with
      | false, () -> ()
      | _ -> failwith "later connection close lost cleanup failure"
      | exception Exit when fail_cleanup -> ())
    [ false; true ]

let rendered_wait_cleanup ~sw ~process_mgr ~mono_clock ~binary endpoint =
  let module Io = Libtmux_unix__Runtime_io in
  let module Cleanup = Libtmux_unix__Cleanup in
  let module Connection = Libtmux_unix__Connection in
  let cleanup = Cleanup.create () in
  let io = Libtmux_eio__Runtime.create ~sw ~process_mgr ~mono_clock ~cleanup in
  let connection = Connection.connect ~io ~binary endpoint in
  Fun.protect
    ~finally:(fun () -> Connection.close connection)
    (fun () ->
      let snapshot = Libtmux_unix__Acquisition.snapshot connection in
      let pane = Iarray.get (Snapshot.panes snapshot) 0 in
      let failures = ref [] in
      List.iter
        (fun mode ->
          let captures = ref 0 and subscriptions = ref 0 and closes = ref 0 in
          let issues () =
            (get (Libtmux_unix.Cleanup.inspect cleanup)).issues |> Iarray.length
          in
          let before = issues () in
          let outcome =
            try
              Eio.Cancel.sub (fun context ->
                  Libtmux_unix__Observation_wait.rendered ~connection
                    ~capture:(fun () -> Ok snapshot)
                    ~capture_text:(fun _ ->
                      incr captures;
                      (match mode with
                      | `Primary -> Io.fail Error.Deadline_exceeded
                      | `Blocking_cancel ->
                          raise Libtmux_unix.Cancellation.Cancelled
                      | `Eio_cancel ->
                          Eio.Cancel.cancel context Stop_waiting;
                          Eio.Fiber.check ()
                      | `Match | `Gap -> ());
                      Ok
                        Captured_text.
                          {
                            bytes =
                              (if mode = `Gap && !captures = 1 then "pending"
                               else "ready");
                            source = Pane.source pane;
                            pane = Pane.id pane;
                            started_at_ns = 0L;
                            finished_at_ns = 1L;
                          })
                    ~subscribe:(fun _ ->
                      incr subscriptions;
                      Ok ())
                    ~next:(fun _ () ->
                      Ok
                        (Some
                           (Output.Gap
                              {
                                after = None;
                                lost_bytes = None;
                                reason = Overflow;
                              })))
                    ~poll:(fun () -> Ok None)
                    ~close:(fun () ->
                      incr closes;
                      Eio.Cancel.protect (fun () ->
                          Io.protect (fun () ->
                              Cleanup.step cleanup Notify_waiters (fun () ->
                                  match mode with
                                  | `Match | `Gap -> Io.fail Error.Closed
                                  | _ -> raise Cleanup_failed))))
                    ~timeout:1. pane ~text:"ready")
              |> fun _ -> None
            with exn -> Some exn
          in
          let name, preserved =
            match (mode, outcome) with
            | `Primary, Some (Io.Failure Error.Deadline_exceeded) ->
                ("primary", true)
            | `Blocking_cancel, Some Libtmux_unix.Cancellation.Cancelled ->
                ("blocking cancellation", true)
            | `Eio_cancel, Some (Eio.Cancel.Cancelled Stop_waiting) ->
                ("Eio cancellation", true)
            | `Match, Some (Io.Failure Error.Closed) -> ("match cleanup", true)
            | `Gap, Some (Io.Failure Error.Closed) -> ("gap cleanup", true)
            | _ ->
                let name =
                  match mode with
                  | `Primary -> "primary"
                  | `Blocking_cancel -> "blocking cancellation"
                  | `Eio_cancel -> "Eio cancellation"
                  | `Match -> "match cleanup"
                  | `Gap -> "gap cleanup"
                in
                (name, false)
          in
          if
            (not preserved) || !captures <> 1 || !subscriptions <> 1
            || !closes <> 1
            || issues () <> before + 1
            || connection.budget.used <> 0
          then failures := name :: !failures)
        [ `Primary; `Blocking_cancel; `Eio_cancel; `Match; `Gap ];
      if !failures <> [] then
        failwith ("rendered wait cleanup: " ^ String.concat ", " !failures))

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          rendered_wait_cleanup ~sw
            ~process_mgr:(Eio.Stdenv.process_mgr env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~binary:Sys.argv.(1)
            (Endpoint.socket_path Sys.argv.(2)));
      Eio.Switch.run (fun sw ->
          overlapping_connection_close ~sw
            ~process_mgr:(Eio.Stdenv.process_mgr env)
            ~mono_clock:(Eio.Stdenv.mono_clock env)
            ~binary:Sys.argv.(1)
            (Endpoint.socket_path Sys.argv.(2)));
      Eio.Switch.run (fun sw ->
          let client =
            get
              (C.connect ~sw
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 ~binary:Sys.argv.(1)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          Fun.protect
            ~finally:(fun () -> get (C.close client))
            (fun () ->
              let snapshot = get (C.capture client) in
              let pids snapshot =
                Snapshot.clients snapshot |> Iarray.to_seq
                |> Seq.map Client_observation.pid
                |> List.of_seq
              in
              let before = pids snapshot in
              let pane = Iarray.get (Snapshot.panes snapshot) 0 in
              let subscription = get (C.subscribe client pane) in
              let helper =
                match
                  pids (get (C.capture client))
                  |> List.filter (fun pid -> not (List.mem pid before))
                with
                | [ pid ] -> pid
                | _ -> failwith "expected one owned stream helper"
              in
              Unix.kill helper Sys.sigstop;
              let first =
                Eio.Fiber.fork_promise ~sw (fun () ->
                    get (Libtmux_eio.Subscription.close subscription))
              in
              let result = Libtmux_eio.Subscription.close subscription in
              let returned_before_reap =
                Sys.file_exists (Printf.sprintf "/proc/%d" helper)
              in
              Eio.Promise.await_exn first;
              get result;
              if returned_before_reap then
                failwith
                  "second subscription close returned before helper reaping"));
      Eio.Switch.run (fun sw ->
          let client =
            get
              (C.connect ~sw
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 ~binary:Sys.argv.(1)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          let pane = Iarray.get (Snapshot.panes (get (C.capture client))) 0 in
          ignore (get (C.subscribe client pane));
          let closing =
            Eio.Fiber.fork_promise ~sw (fun () -> get (C.close client))
          in
          Fun.protect
            ~finally:(fun () -> Eio.Promise.await_exn closing)
            (fun () ->
              assert (not (Eio.Promise.is_resolved closing));
              (match
                 C.submit client (Operations.signal "after-close-started")
               with
              | Error Error.Closed -> ()
              | _ -> failwith "closing client admitted a new command");
              match C.subscribe ~capacity_bytes:0 client pane with
              | Error Error.Closed -> ()
              | _ -> failwith "closing client validated a new subscription"));
      List.iter
        (fun cancel ->
          let retained = ref None and reader_cancelled = ref false in
          (try
             Eio.Switch.run (fun owned ->
                 let client =
                   get
                     (C.connect ~sw:owned
                        ~process_mgr:(Eio.Stdenv.process_mgr env)
                        ~mono_clock:(Eio.Stdenv.mono_clock env)
                        ~binary:Sys.argv.(1)
                        (Endpoint.socket_path Sys.argv.(2)))
                 in
                 let pane =
                   Iarray.get (Snapshot.panes (get (C.capture client))) 0
                 in
                 let subscription = get (C.subscribe client pane) in
                 let operation =
                   get (C.submit client (Operations.wait_for "scope-teardown"))
                 in
                 retained := Some operation;
                 assert (
                   get (O.await_stage operation `Acknowledged) = O.Acknowledged);
                 Eio.Fiber.fork_daemon ~sw:owned (fun () ->
                     (try
                        ignore
                          (get
                             (Libtmux_eio.Subscription.next ~timeout:0.5
                                subscription));
                        failwith
                          "pending stream read returned before scope \
                           cancellation"
                      with Eio.Cancel.Cancelled _ -> reader_cancelled := true);
                     `Stop_daemon);
                 if cancel then raise Stop_waiting)
           with Stop_waiting when cancel -> ());
          assert !reader_cancelled;
          assert (
            match get (O.inspect (Option.get !retained)) with
            | O.Outcome_unknown _ -> true
            | _ -> false))
        [ false; true ];
      Eio.Switch.run (fun sw ->
          let client =
            get
              (C.connect ~sw
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 ~binary:Sys.argv.(1)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          Fun.protect
            ~finally:(fun () -> ignore (get (C.close client)))
            (fun () ->
              let queued =
                get
                  (C.submit client (Operations.signal "cancelled-before-write"))
              in
              let wrong_domain =
                Domain.spawn (fun () -> C.await queued) |> Domain.join
              in
              assert (
                match wrong_domain with
                | Error Error.Wrong_domain -> true
                | _ -> false);
              cancel_wait queued;
              assert (get (O.inspect queued) = O.Not_started);
              let snapshot = get (C.capture client) in
              let pane =
                Option.get
                  (Snapshot.find_pane snapshot (get (Pane.Id.of_string "%1")))
              in
              let text = get (C.capture_text client pane ~start:0 ~end_:2) in
              assert (text.bytes = "%end 1 1 1\nhello\n\n");
              let waits =
                List.init 8 (fun index ->
                    get
                      (C.submit client
                         (Operations.wait_for ("pool-" ^ Int.to_string index))))
              in
              List.iteri
                (fun index op ->
                  let state = get (O.await_stage op `Acknowledged) in
                  if index < 7 then
                    assert (
                      match state with O.Acknowledged -> true | _ -> false)
                  else
                    assert (
                      match state with
                      | O.Finished (Error (Error.Capacity _)) -> true
                      | _ -> false))
                waits;
              ignore (get (C.capture_text client pane ~start:0 ~end_:2));
              List.iteri
                (fun index op ->
                  if index < 7 then (
                    ignore
                      (get
                         (C.run client
                            (Operations.signal ("pool-" ^ Int.to_string index))));
                    ignore (get (C.await op))))
                waits;
              List.iter
                (fun stage ->
                  let waiting =
                    get (C.submit client (Operations.wait_for "owned-drain"))
                  in
                  let reached = get (O.await_stage waiting stage) in
                  assert (
                    match reached with
                    | O.Written | O.Acknowledged -> true
                    | _ -> false);
                  cancel_wait waiting;
                  assert (
                    match get (O.inspect waiting) with
                    | O.Written | O.Acknowledged -> true
                    | _ -> false);
                  ignore (get (C.run client (Operations.signal "owned-drain")));
                  ignore (get (C.await waiting));
                  assert (
                    match get (O.inspect waiting) with
                    | O.Finished (Ok ()) -> true
                    | _ -> false);
                  cancel_wait waiting;
                  assert (
                    match get (O.inspect waiting) with
                    | O.Finished (Ok ()) -> true
                    | _ -> false))
                [ `Written; `Acknowledged ];
              let unknown =
                get (C.submit client (Operations.wait_for "will-not-complete"))
              in
              ignore (get (O.await_stage unknown `Acknowledged));
              let finished, publish = Eio.Promise.create () in
              let foreign =
                Domain.spawn (fun () ->
                    Eio_main.run (fun _ ->
                        Eio.Promise.resolve publish
                          (try Ok (C.close client) with exn -> Error exn)))
              in
              let foreign_result =
                Fun.protect
                  ~finally:(fun () ->
                    ignore (get (C.close client));
                    Domain.join foreign)
                  (fun () ->
                    Eio.Fiber.first
                      (fun () -> Eio.Promise.await_exn finished)
                      (fun () ->
                        Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.5;
                        failwith "foreign-domain close waited on owned workers"))
              in
              assert (foreign_result = Error Error.Wrong_domain);
              assert (
                match get (O.inspect unknown) with
                | O.Outcome_unknown _ -> true
                | _ -> false);
              assert (Iarray.length (Snapshot.panes snapshot) = 2);
              print_endline "PASS Eio ownership")))
