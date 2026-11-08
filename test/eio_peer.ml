open Libtmux
module C = Libtmux_eio.Client
module O = Libtmux_eio.Operation

let get = function
  | Ok value -> value
  | Error e -> failwith (Format.asprintf "%a" Error.pp e)

exception Stop_waiting

let cancel_wait op =
  let cancelled = ref false in
  (try
     Eio.Cancel.sub (fun context ->
         Eio.Cancel.cancel context Stop_waiting;
         ignore (C.await op))
   with Eio.Cancel.Cancelled Stop_waiting -> cancelled := true);
  assert !cancelled

let () =
  Eio_main.run (fun env ->
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
