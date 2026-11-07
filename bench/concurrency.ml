open Libtmux
module Client = Libtmux_eio.Client
module Subscription = Libtmux_eio.Subscription

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let elapsed clock start =
  Mtime.span start (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns
  |> fun ns -> ns /. 1e9

let requests clock client session count concurrency =
  let allocation = Gc.allocated_bytes () in
  let phase_start = Eio.Time.Mono.now clock in
  let rows =
    List.init count Fun.id
    |> Eio.Fiber.List.map ~max_fibers:concurrency (fun index ->
        let option_index = index mod concurrency in
        let start = Eio.Time.Mono.now clock in
        let value =
          get
            (Client.read_option client (Options.Session session)
               (Printf.sprintf "@bench-%d" option_index))
        in
        let expected = Printf.sprintf "value-%d" option_index in
        (match value with
        | Some (Options.Scalar (Options.Text actual)) when actual = expected ->
            ()
        | _ -> failwith "concurrent response attribution differs");
        `Assoc
          [
            ("index", `Int index);
            ("value", `String expected);
            ("seconds", `Float (elapsed clock start));
          ])
  in
  `Assoc
    [
      ("seconds", `Float (elapsed clock phase_start));
      ("loop_allocated_bytes", `Float (Gc.allocated_bytes () -. allocation));
      ("rows", `List rows);
    ]

let output clock client pane count ready =
  let subscription =
    get (Client.subscribe ~capacity_bytes:65_536 client pane)
  in
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> get (Subscription.close subscription)))
    (fun () ->
      let clients =
        get (Client.capture client) |> Snapshot.clients |> Iarray.length
      in
      assert (clients = 2);
      ready ();
      let previous = ref 0L in
      let samples =
        List.init count (fun index ->
            let text = Printf.sprintf "libtmux-bench-stream-%06d" index in
            let start = Eio.Time.Mono.now clock in
            let seconds, () =
              Eio.Fiber.pair
                (fun () ->
                  match
                    Subscription.wait_for_bytes ~timeout:1. subscription ~text
                  with
                  | Ok cursor ->
                      assert (cursor.offset > !previous);
                      previous := cursor.offset;
                      elapsed clock start
                  | Error _ ->
                      failwith "stream continuity or observation failed")
                (fun () ->
                  get (Client.send_text client (Pane.target pane) ~text);
                  get (Client.send_keys client (Pane.target pane) [ Key.Enter ]))
            in
            `Float seconds)
      in
      `List samples)

let cancellation clock client pane count =
  List.init count (fun _ ->
      let subscription =
        get (Client.subscribe ~capacity_bytes:4096 client pane)
      in
      Fun.protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () -> get (Subscription.close subscription)))
        (fun () ->
          let entered, enter = Eio.Promise.create () in
          let context = ref None and cancelled_at = ref None in
          let seconds, () =
            Eio.Fiber.pair
              (fun () ->
                try
                  Eio.Cancel.sub (fun current ->
                      context := Some current;
                      Eio.Promise.resolve enter ();
                      ignore
                        (Subscription.wait_for_bytes ~timeout:1. subscription
                           ~text:"libtmux-benchmark-never-sent");
                      failwith "wait completed before cancellation")
                with Eio.Cancel.Cancelled _ ->
                  elapsed clock (Option.get !cancelled_at))
              (fun () ->
                Eio.Promise.await entered;
                cancelled_at := Some (Eio.Time.Mono.now clock);
                Eio.Cancel.cancel (Option.get !context)
                  (Failure "benchmark cancellation"))
          in
          `Float seconds))

let () =
  if Array.length Sys.argv <> 7 then
    failwith
      "usage: concurrency TMUX_BINARY SOCKET REQUESTS CONCURRENCY STREAMS \
       CANCELS";
  let count = int_of_string Sys.argv.(3)
  and concurrency = int_of_string Sys.argv.(4)
  and streams = int_of_string Sys.argv.(5)
  and cancels = int_of_string Sys.argv.(6) in
  if
    count < 1 || count > 1000 || concurrency < 1 || concurrency > 64
    || streams < 1 || streams > 100 || cancels < 1 || cancels > 100
  then failwith "benchmark size outside bounds";
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let clock = Eio.Stdenv.mono_clock env in
          let client =
            get
              (Client.connect ~sw ~binary:Sys.argv.(1)
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:clock
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          Fun.protect
            ~finally:(fun () ->
              Eio.Cancel.protect (fun () -> get (Client.close client)))
            (fun () ->
              let snapshot = get (Client.capture client) in
              assert (Iarray.length (Snapshot.clients snapshot) = 1);
              let pane = Iarray.get (Snapshot.panes snapshot) 0 in
              let session =
                Session.target (Iarray.get (Snapshot.sessions snapshot) 0)
              in
              ignore
                (get
                   (Client.wait_for_text ~timeout:1. client pane
                      ~text:"bench ready"));
              print_endline "READY";
              let input =
                Eio.Buf_read.of_flow ~max_size:64 (Eio.Stdenv.stdin env)
              in
              assert (Eio.Buf_read.line input = "run");
              let request_results =
                requests clock client session count concurrency
              in
              let stream_samples =
                output clock client pane streams (fun () ->
                    print_endline "STREAM_READY";
                    assert (Eio.Buf_read.line input = "stream"))
              in
              let cancellation_samples =
                cancellation clock client pane cancels
              in
              assert (
                get (Client.capture client)
                |> Snapshot.clients |> Iarray.length = 1);
              Yojson.Safe.to_channel stdout
                (`Assoc
                   [
                     ("requests", request_results);
                     ("stream_seconds", stream_samples);
                     ("cancellation_seconds", `List cancellation_samples);
                     ("max_clients", `Int 2);
                   ]);
              print_newline ())))
