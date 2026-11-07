open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

type subscription = {
  next : unit -> Output.event option;
  poll : unit -> Output.event option;
  close : unit -> unit;
  wait : string -> (Output.cursor, Output.wait_error) result;
  cancel_wait : unit -> unit;
  timeout : unit -> unit;
}

type runner = {
  run : 'a. 'a Command.t -> 'a;
  subscribe : ?capacity_events:int -> int -> Pane.t -> subscription;
  close : unit -> unit;
  line : unit -> string;
  rendered : Pane.t -> string -> (Captured_text.t, Error.t) result;
  reject_subscription : Pane.t -> unit;
  reject_lane : Pane.t -> unit;
}

exception Cancel_wait

let read_bytes sub expected =
  let result = Buffer.create 256 in
  let cursor = ref None in
  while Buffer.length result < String.length expected do
    match sub.next () with
    | Some (Output.Data { bytes; cursor = current }) ->
        Option.iter
          (fun before ->
            assert (Generation.equal before.Output.generation current.generation);
            assert (
              current.offset
              = Int64.add before.offset (Int64.of_int (String.length bytes))))
          !cursor;
        cursor := Some current;
        Buffer.add_string result bytes
    | Some (Gap { reason; _ } | End reason) ->
        failwith
          (Format.asprintf "unexpected stream end: %a" Output.reason_pp reason)
    | None -> failwith "stream ended before data"
  done;
  assert (Buffer.contents result = expected);
  Option.get !cursor

let gap sub reason =
  (match sub.next () with
  | Some (Output.Gap { reason = actual; _ }) when actual = reason -> ()
  | _ -> failwith "missing gap");
  assert (sub.next () = Some (Output.End reason));
  assert (sub.next () = None)

let exercise runner =
  let capture () = runner.run (Operations.capture ()) in
  let snapshot = capture () in
  let pane = Iarray.get (Snapshot.panes snapshot) 0 in
  let first = runner.subscribe 4096 pane in
  let slow = runner.subscribe 16 pane in
  let second = runner.subscribe 4096 pane in
  let event_limited = runner.subscribe ~capacity_events:1 4096 pane in
  assert (Iarray.length (Snapshot.clients (capture ())) = 2);
  print_endline "READY";
  let expected = String.init 256 Char.chr ^ "DONE" in
  let before = read_bytes first expected in
  let other = read_bytes second expected in
  assert (not (Generation.equal before.generation other.generation));
  (match slow.next () with
  | Some (Output.Gap { reason = Overflow; lost_bytes = Some lost; _ }) ->
      assert (lost >= 256)
  | _ -> failwith "stalled subscriber did not report byte loss");
  assert (slow.next () = Some (Output.End Overflow));
  assert (first.poll () = None);
  print_endline "EVENT_LIMIT";
  assert (Iarray.length (Snapshot.clients (capture ())) = 2);
  ignore (read_bytes first "recovered");
  ignore (read_bytes second "recovered");
  (match event_limited.next () with
  | Some
      (Output.Gap { reason = Overflow; after = None; lost_bytes = Some lost })
    ->
      assert (lost > 0 && lost <= 269)
  | _ -> failwith "event-count limit did not report loss independently of bytes");
  assert (event_limited.next () = Some (Output.End Overflow));
  second.close ();
  print_endline "CHANGE";
  gap first Output.Membership_changed;
  let fresh = Iarray.get (Snapshot.panes (capture ())) 0 in
  let recovered = runner.subscribe 4096 fresh in
  print_endline "RECOVER";
  let after = read_bytes recovered "recovered" in
  assert (not (Generation.equal before.generation after.generation));
  print_endline "FUTURE";
  (match recovered.wait "future\000match" with
  | Ok cursor ->
      assert (Generation.equal cursor.generation after.generation);
      assert (cursor.offset = 23L)
  | Error _ -> failwith "future-byte match failed");
  recovered.timeout ();
  print_endline "RENDER";
  let present = get (runner.rendered fresh "present-value") in
  assert (String.starts_with ~prefix:"present-value" present.bytes);
  let retained = get (runner.rendered fresh "present-value") in
  assert (String.starts_with ~prefix:"present-value" retained.bytes);
  ignore (read_bytes recovered "\027c\027[Hpresent-value");
  print_endline "DETACH";
  (match recovered.wait "absent-future-value" with
  | Error (Output.Ended (Transport_error (Error.Disconnected _) as reason)) ->
      assert (recovered.next () = Some (Output.End reason));
      assert (recovered.next () = None)
  | _ -> failwith "lost stream continued matching without an explicit gap");
  assert (Iarray.length (Snapshot.clients (capture ())) = 1);
  let recovered =
    runner.subscribe 4096 (Iarray.get (Snapshot.panes (capture ())) 0)
  in
  print_endline "RECOVER_AGAIN";
  let renewed = read_bytes recovered "recovered" in
  assert (not (Generation.equal renewed.generation after.generation));
  recovered.close ();
  assert (recovered.next () = Some (Output.End Cancelled));
  let subscriptions = List.init 16 (fun _ -> runner.subscribe 1024 fresh) in
  runner.reject_subscription fresh;
  assert (Iarray.length (Snapshot.clients (capture ())) = 2);
  print_endline "CAPACITY";
  assert (runner.line () = "CHECKED");
  List.iter (fun (sub : subscription) -> sub.close ()) subscriptions;
  let cancelled = runner.subscribe 1024 fresh in
  print_endline "CANCEL_READY";
  cancelled.cancel_wait ();
  assert (cancelled.poll () = Some (Output.End Cancelled));
  assert (Iarray.length (Snapshot.clients (capture ())) = 1);
  let created =
    List.init 8 (fun index ->
        runner.run
          (Operations.create_session
             ~name:(Printf.sprintf "coverage-%d" index)
             ~spawn:(Spawn.make (Exec { program = "/bin/cat"; args = [] }))
             ()))
  in
  let observed = capture () in
  let pane_of (created : Created.t) =
    Option.get (Snapshot.find_pane observed (Pane.Target.id created.pane))
  in
  let covered =
    List.take 7 created
    |> List.map (fun value -> runner.subscribe 128 (pane_of value))
  in
  runner.reject_lane (pane_of (List.nth created 7));
  assert (Iarray.length (Snapshot.clients (capture ())) = 8);
  runner.run
    (Operations.send_text (List.nth created 0).pane ~text:"left-session");
  runner.run
    (Operations.send_text (List.nth created 1).pane ~text:"right-session");
  ignore (read_bytes (List.nth covered 0) "left-session");
  ignore (read_bytes (List.nth covered 1) "right-session");
  List.iteri
    (fun index (sub : subscription) ->
      if index > 1 then assert (sub.poll () = None))
    covered;
  print_endline "LANE_CAPACITY";
  assert (runner.line () = "CHECKED");
  List.iter (fun (sub : subscription) -> sub.close ()) covered;
  List.iter
    (fun (created : Created.t) ->
      runner.run (Operations.kill_session created.session))
    created;
  let final = runner.subscribe 1024 fresh in
  runner.close ();
  gap final Output.Client_closed;
  print_endline
    "PASS bytes, cursors, shared lanes, overflow, coverage and closure"

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  if Sys.argv.(3) = "unix" then
    let module C = Libtmux_unix.Client in
    let module S = Libtmux_unix.Subscription in
    let client = get (C.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (C.close client)))
      (fun () ->
        exercise
          {
            run = (fun command -> get (C.run client command));
            subscribe =
              (fun ?capacity_events capacity_bytes pane ->
                let sub =
                  get (C.subscribe ?capacity_events ~capacity_bytes client pane)
                in
                {
                  next = (fun () -> get (S.next ~timeout:0.5 sub));
                  poll = (fun () -> get (S.poll sub));
                  close = (fun () -> get (S.close sub));
                  wait = (fun text -> S.wait_for_bytes ~timeout:0.5 sub ~text);
                  timeout =
                    (fun () ->
                      match
                        S.wait_for_bytes ~timeout:0.01 sub
                          ~text:"absent-byte-pattern"
                      with
                      | Error (Output.Failure Error.Deadline_exceeded) -> ()
                      | _ ->
                          failwith
                            "future-byte deadline did not remain \
                             distinguishable");
                  cancel_wait =
                    (fun () ->
                      Libtmux_unix.Cancellation.with_ (fun cancel ->
                          let canceller =
                            Domain.spawn (fun () ->
                                assert (read_line () = "CANCEL");
                                Libtmux_unix.Cancellation.cancel cancel)
                          in
                          Fun.protect
                            ~finally:(fun () -> Domain.join canceller)
                            (fun () ->
                              match S.next ~cancel ~timeout:0.5 sub with
                              | _ -> failwith "cancelled byte read returned"
                              | exception Libtmux_unix.Cancellation.Cancelled ->
                                  ())));
                });
            close = (fun () -> get (C.close client));
            line = read_line;
            rendered =
              (fun pane text -> C.wait_for_text ~timeout:0.5 client pane ~text);
            reject_lane =
              (fun pane ->
                match C.subscribe client pane with
                | Error
                    (Error.Capacity { resource = "client lanes"; limit = 8 }) ->
                    ()
                | _ -> failwith "lane limit did not reject before admission");
            reject_subscription =
              (fun pane ->
                match C.subscribe client pane with
                | Error
                    (Error.Capacity { resource = "subscriptions"; limit = 16 })
                  ->
                    ()
                | _ ->
                    failwith "subscriber limit did not reject before admission");
          })
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let module C = Libtmux_eio.Client in
            let module S = Libtmux_eio.Subscription in
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
                exercise
                  {
                    run = (fun command -> get (C.run client command));
                    subscribe =
                      (fun ?capacity_events capacity_bytes pane ->
                        let sub =
                          get
                            (C.subscribe ?capacity_events ~capacity_bytes client
                               pane)
                        in
                        {
                          next = (fun () -> get (S.next ~timeout:0.5 sub));
                          poll = (fun () -> get (S.poll sub));
                          close = (fun () -> get (S.close sub));
                          wait =
                            (fun text ->
                              S.wait_for_bytes ~timeout:0.5 sub ~text);
                          timeout =
                            (fun () ->
                              match
                                S.wait_for_bytes ~timeout:0.01 sub
                                  ~text:"absent-byte-pattern"
                              with
                              | Error (Output.Failure Error.Deadline_exceeded)
                                ->
                                  ()
                              | _ ->
                                  failwith
                                    "future-byte deadline did not remain \
                                     distinguishable");
                          cancel_wait =
                            (fun () ->
                              let context, resolve = Eio.Promise.create () in
                              let cancelled =
                                Eio.Fiber.fork_promise ~sw (fun () ->
                                    Eio.Cancel.sub (fun scope ->
                                        Eio.Promise.resolve resolve scope;
                                        match S.next ~timeout:0.5 sub with
                                        | _ ->
                                            failwith
                                              "cancelled byte read returned"
                                        | exception
                                            Eio.Cancel.Cancelled Cancel_wait ->
                                            ()))
                              in
                              let scope = Eio.Promise.await context in
                              assert (Eio.Buf_read.line input = "CANCEL");
                              Eio.Cancel.cancel scope Cancel_wait;
                              Eio.Promise.await_exn cancelled);
                        });
                    close = (fun () -> get (C.close client));
                    line = (fun () -> Eio.Buf_read.line input);
                    rendered =
                      (fun pane text ->
                        C.wait_for_text ~timeout:0.5 client pane ~text);
                    reject_lane =
                      (fun pane ->
                        match C.subscribe client pane with
                        | Error
                            (Error.Capacity
                               { resource = "client lanes"; limit = 8 }) ->
                            ()
                        | _ ->
                            failwith
                              "lane limit did not reject before admission");
                    reject_subscription =
                      (fun pane ->
                        match C.subscribe client pane with
                        | Error
                            (Error.Capacity
                               { resource = "subscriptions"; limit = 16 }) ->
                            ()
                        | _ ->
                            failwith
                              "subscriber limit did not reject before admission");
                  })))
