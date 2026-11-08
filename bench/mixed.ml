open Libtmux
module C = Libtmux_eio.Client
module O = Libtmux_eio.Operation
module S = Libtmux_eio.Subscription

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let require condition message = if not condition then failwith message
let json fields = `Assoc fields

let elapsed clock start =
  Mtime.span start (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns
  |> fun value -> value /. 1e9

let read_file path = In_channel.with_open_bin path In_channel.input_all

let process_rows pid =
  let base = "/proc/" ^ Int.to_string pid in
  try
    let status = read_file (base ^ "/status") |> String.split_on_char '\n' in
    let bytes name =
      let line = List.find (String.starts_with ~prefix:(name ^ ":")) status in
      let fields =
        String.split_on_char ' '
          (String.map (fun c -> if c = '\t' then ' ' else c) line)
        |> List.filter (( <> ) "")
      in
      1024 * int_of_string (List.nth fields 1)
    in
    let stat = read_file (base ^ "/stat") in
    let start = String.rindex stat ')' + 2 in
    let fields =
      String.sub stat start (String.length stat - start)
      |> String.split_on_char ' '
    in
    json
      [
        ("pid", `Int pid);
        ("start_ticks", `Intlit (List.nth fields 19));
        ("rss_bytes", `Int (bytes "VmRSS"));
        ("rss_high_water_bytes", `Int (bytes "VmHWM"));
        ("fd_count", `Int (Array.length (Sys.readdir (base ^ "/fd"))));
      ]
  with Sys_error _ | Not_found ->
    json [ ("pid", `Int pid); ("unavailable_during_sample", `Bool true) ]

let descendants pid =
  let children pid =
    let base = "/proc/" ^ Int.to_string pid ^ "/task/" in
    try
      Sys.readdir base |> Array.to_list
      |> List.concat_map (fun tid ->
          try
            read_file (base ^ tid ^ "/children")
            |> String.trim |> String.split_on_char ' '
            |> List.filter (( <> ) "")
            |> List.map int_of_string
          with Sys_error _ -> [])
    with Sys_error _ -> []
  in
  let rec visit seen = function
    | [] -> seen
    | pid :: rest when List.mem pid seen -> visit seen rest
    | pid :: rest ->
        require
          (List.length seen < 128)
          "owned process tree exceeded benchmark bound";
        visit (pid :: seen) (children pid @ rest)
  in
  visit [] (children pid)

let resource_sample daemon =
  let own = Unix.getpid () in
  json
    (List.map
       (fun (name, pids) -> (name, `List (List.map process_rows pids)))
       [
         ("harness", [ Unix.getppid () ]);
         ("benchmark", [ own ]);
         ("daemon", [ daemon ]);
         ("benchmark_children", descendants own);
         ("daemon_children", descendants daemon);
       ])

exception Stop_observing

type request = {
  index : int;
  worker : int;
  name : string;
  value : string;
  operation : unit O.t;
  submitted : Mtime.t;
  cancelled : bool;
}

type cursor = { mutable previous : Output.cursor option }

let data cursor current bytes =
  let offset =
    match cursor.previous with
    | None -> 0L
    | Some previous ->
        require
          (Generation.equal previous.generation current.Output.generation)
          "stream changed generation without explicit readmission";
        previous.offset
  in
  require
    (current.offset = Int64.add offset (Int64.of_int (String.length bytes)))
    "stream cursor byte attribution differs";
  cursor.previous <- Some current

let read_message sub cursor expected =
  let bytes = Buffer.create (String.length expected) in
  while Buffer.length bytes < String.length expected do
    match get (S.next sub) with
    | Some (Output.Data { cursor = current; bytes = chunk }) ->
        data cursor current chunk;
        Buffer.add_string bytes chunk
    | Some (Gap { reason; _ } | End reason) ->
        failwith
          (Format.asprintf "unexpected fast-reader gap: %a" Output.reason_pp
             reason)
    | None -> failwith "fast stream ended before its attributed message"
  done;
  require
    (Buffer.contents bytes = expected)
    "stream bytes or message order differ"

let gap ?(discard_data = false) sub reason =
  let rec next () =
    match get (S.next sub) with
    | Some (Output.Data _) when discard_data -> next ()
    | Some (Gap { reason = actual; lost_bytes; _ }) when actual = reason ->
        if reason = Output.Overflow then
          require
            (Option.value ~default:0 lost_bytes > 0)
            "overflow reported no lost bytes";
        lost_bytes
    | _ -> failwith "missing expected explicit Gap"
  in
  let lost = next () in
  require
    (get (S.next sub) = Some (Output.End reason))
    "Gap did not precede End";
  require (get (S.next sub) = None) "stream continued after End";
  lost

let capacity resource limit = function
  | Error (Error.Capacity actual)
    when actual.resource = resource && actual.limit = limit ->
      ()
  | _ -> failwith ("missing expected admission rejection: " ^ resource)

let cancel_observer clock operation =
  let entered, enter = Eio.Promise.create () in
  let cancelled_at = ref None in
  let seconds, () =
    Eio.Fiber.pair
      (fun () ->
        try
          Eio.Cancel.sub (fun context ->
              Eio.Promise.resolve enter context;
              ignore (C.await operation);
              failwith "unsignalled retained wait completed")
        with Eio.Cancel.Cancelled Stop_observing ->
          elapsed clock (Option.get !cancelled_at))
      (fun () ->
        let context = Eio.Promise.await entered in
        cancelled_at := Some (Eio.Time.Mono.now clock);
        Eio.Cancel.cancel context Stop_observing)
  in
  seconds

let run env sw binary socket rounds workers frames payload =
  let clock = Eio.Stdenv.mono_clock env in
  let connect () =
    get
      (C.connect ~sw ~binary
         ~process_mgr:(Eio.Stdenv.process_mgr env)
         ~mono_clock:clock
         (Endpoint.socket_path socket))
  in
  let load = connect () in
  Fun.protect
    ~finally:(fun () -> Eio.Cancel.protect (fun () -> get (C.close load)))
    (fun () ->
      let controller = connect () in
      Fun.protect
        ~finally:(fun () ->
          Eio.Cancel.protect (fun () -> get (C.close controller)))
        (fun () ->
          let input =
            Eio.Buf_read.of_flow ~max_size:64 (Eio.Stdenv.stdin env)
          in
          let telemetry = Eio.Mutex.create () in
          let started = Eio.Time.Mono.now clock in
          let checkpoint ?(current = fun () -> []) event fields =
            let occurred = elapsed clock started in
            let occurrence = current () in
            (* Snapshot before yielding to telemetry: the owner cannot drain its queue during these reads. *)
            let resources =
              if occurrence = [] then `Null
              else resource_sample (Source.server_pid (C.source load))
            in
            let sampled = elapsed clock started in
            Eio.Mutex.use_rw ~protect:false telemetry (fun () ->
                Yojson.Safe.to_channel stdout
                  (json
                     (("event", `String event)
                     :: ("occurred_seconds", `Float occurred)
                     :: ("occurrence", json occurrence)
                     :: ("occurrence_resources", resources)
                     :: ("resource_sample_finished_seconds", `Float sampled)
                     :: ("seconds", `Float (elapsed clock started))
                     :: (current () @ fields)));
                print_newline ();
                require
                  (Eio.Buf_read.line input = "continue")
                  "invalid observer handshake")
          in
          let snapshot = get (C.capture load) in
          let sessions = Snapshot.sessions snapshot |> Iarray.to_list in
          let session number =
            List.find
              (fun session ->
                Session.name session = "mixed-" ^ Int.to_string number)
              sessions
          in
          let panes =
            Array.init 8 (fun index ->
                let windows = Session.windows (session index) in
                Iarray.get (Window.panes (Iarray.get windows 0)) 0)
          in
          let control_snapshot = get (C.capture controller) in
          let control_panes =
            Array.map
              (fun pane ->
                Option.get (Snapshot.find_pane control_snapshot (Pane.id pane)))
              panes
          in
          Array.iteri
            (fun index pane ->
              ignore
                (get
                   (C.wait_for_text controller pane
                      ~text:("mixed ready " ^ Int.to_string index))))
            control_panes;
          checkpoint "ready" [];
          let requests = ref []
          and completions = ref []
          and streams = ref []
          and cancellations = ref []
          and rejections = ref []
          and gaps = ref [] in
          let retained = ref [] in
          for round = 0 to rounds - 1 do
            let subscriptions = ref [] in
            let subscribe ?(capacity_bytes = 65_536) index pane =
              let sub =
                get
                  (C.subscribe
                     ~session:(Session.target (session index))
                     ~capacity_bytes ~capacity_events:1024 load pane)
              in
              subscriptions := sub :: !subscriptions;
              sub
            in
            Fun.protect
              ~finally:(fun () ->
                Eio.Cancel.protect (fun () ->
                    List.iter (fun sub -> get (S.close sub)) !subscriptions))
              (fun () ->
                let fast =
                  Array.init 7 (fun index ->
                      ref (subscribe index panes.(index)))
                in
                let slow =
                  Array.init 7 (fun index ->
                      subscribe ~capacity_bytes:128 index panes.(index))
                in
                let membership = subscribe 6 panes.(6) in
                let extra = subscribe 0 panes.(0) in
                capacity "subscriptions" 16 (C.subscribe load panes.(0));
                get (S.close extra);
                capacity "client lanes" 8
                  (C.subscribe
                     ~session:(Session.target (session 7))
                     load panes.(7));
                ignore (subscribe 0 panes.(0));
                rejections :=
                  json
                    [
                      ("round", `Int round);
                      ("subscriptions", `Int 1);
                      ("client_lanes", `Int 1);
                      ("admitted_commands", `Int 1);
                    ]
                  :: !rejections;
                checkpoint "subscribers_admitted"
                  [
                    ("round", `Int round);
                    ("subscribers", `Int 16);
                    ("load_client_lanes", `Int 8);
                  ];
                let wave =
                  Array.init 64 (fun index ->
                      let worker = index mod workers in
                      let name = Printf.sprintf "@mixed-r%d-i%d" round index in
                      let value =
                        Printf.sprintf "worker=%d;round=%d;submission=%d" worker
                          round index
                      in
                      let submitted = Eio.Time.Mono.now clock in
                      let operation =
                        get
                          (C.submit load
                             (Operations.set_option
                                (Options.Session (Session.target (session 0)))
                                ~name (Options.Text value)))
                      in
                      {
                        index;
                        worker;
                        name;
                        value;
                        operation;
                        submitted;
                        cancelled = index < 8;
                      })
                in
                require
                  (Array.for_all
                     (fun row -> get (O.inspect row.operation) = O.Queued)
                     wave)
                  "a non-yielding wave was not entirely queued";
                capacity "admitted commands" 64
                  (C.submit load
                     (Operations.signal "mixed-overflow-must-not-run"));
                Array.iter
                  (fun row ->
                    if row.cancelled then (
                      get (O.cancel row.operation);
                      require
                        (get (O.inspect row.operation) = O.Not_started)
                        "queued cancellation lost its state"))
                  wave;
                requests := Array.to_list wave @ !requests;
                let pending () =
                  Array.fold_left
                    (fun count row ->
                      match get (O.inspect row.operation) with
                      | O.Queued | O.Written | O.Acknowledged -> count + 1
                      | _ -> count)
                    0 wave
                in
                let queue_checkpoint () =
                  checkpoint
                    ~current:(fun () ->
                      [ ("commands_pending", `Int (pending ())) ])
                    "queue_admitted"
                    [
                      ("round", `Int round);
                      ("queued_before_cancellation", `Int 64);
                      ("queued_cancelled", `Int 8);
                      ("expected_rejections", `Int 1);
                    ]
                in
                let observed =
                  Array.init 7 (fun _ ->
                      Array.init frames (fun _ -> Eio.Promise.create ()))
                in
                let membership_seen, mark_membership = Eio.Promise.create () in
                let renewed, renew = Eio.Promise.create () in
                let token lane frame =
                  Printf.sprintf "mixed-r%d-l%d-f%d:%s" round lane frame
                    (String.make payload (Char.chr (97 + lane)))
                in
                let reader lane () =
                  let cursor = ref { previous = None } in
                  for frame = 0 to frames - 1 do
                    let before = Eio.Time.Mono.now clock in
                    read_message
                      !(fast.(lane))
                      !cursor
                      (token lane frame ^ "\r\n");
                    let current = Option.get !cursor.previous in
                    streams :=
                      json
                        [
                          ("round", `Int round);
                          ("lane", `Int lane);
                          ("frame", `Int frame);
                          ( "generation",
                            `String (Generation.to_string current.generation) );
                          ("offset", `Intlit (Int64.to_string current.offset));
                          ("read_wait_seconds", `Float (elapsed clock before));
                        ]
                      :: !streams;
                    Eio.Promise.resolve (snd observed.(lane).(frame)) ()
                  done
                in
                let reader lane () =
                  if lane <> 6 then reader lane ()
                  else
                    (* The replacement reader consumes frame one during recovery. *)
                    let cursor = { previous = None } in
                    read_message !(fast.(lane)) cursor (token lane 0 ^ "\r\n");
                    let old = (Option.get cursor.previous).generation in
                    streams :=
                      json
                        [
                          ("round", `Int round);
                          ("lane", `Int lane);
                          ("frame", `Int 0);
                          ("generation", `String (Generation.to_string old));
                          ( "offset",
                            `Intlit
                              (Int64.to_string
                                 (Option.get cursor.previous).offset) );
                        ]
                      :: !streams;
                    Eio.Promise.resolve (snd observed.(lane).(0)) ();
                    ignore (gap !(fast.(lane)) Output.Membership_changed);
                    Eio.Promise.resolve mark_membership ();
                    fast.(lane) := Eio.Promise.await renewed;
                    let cursor = { previous = None } in
                    for frame = 1 to frames - 1 do
                      read_message
                        !(fast.(lane))
                        cursor
                        (token lane frame ^ "\r\n");
                      let current = Option.get cursor.previous in
                      require
                        (not (Generation.equal old current.generation))
                        "membership recovery reused its old generation";
                      streams :=
                        json
                          [
                            ("round", `Int round);
                            ("lane", `Int lane);
                            ("frame", `Int frame);
                            ( "generation",
                              `String (Generation.to_string current.generation)
                            );
                            ("offset", `Intlit (Int64.to_string current.offset));
                          ]
                        :: !streams;
                      Eio.Promise.resolve (snd observed.(lane).(frame)) ()
                    done
                in
                let sender lane () =
                  for frame = 0 to frames - 1 do
                    if lane = 6 && frame = 1 then
                      ignore (Eio.Promise.await renewed);
                    let before = Eio.Time.Mono.now clock in
                    get
                      (C.send_text controller
                         (Pane.target control_panes.(lane))
                         ~text:(token lane frame));
                    get
                      (C.send_keys controller
                         (Pane.target control_panes.(lane))
                         [ Key.Enter ]);
                    Eio.Promise.await (fst observed.(lane).(frame));
                    checkpoint
                      ~current:(fun () ->
                        [ ("commands_pending", `Int (pending ())) ])
                      "stream_observed"
                      [
                        ("round", `Int round);
                        ("lane", `Int lane);
                        ("frame", `Int frame);
                        ("delivery_seconds", `Float (elapsed clock before));
                      ]
                  done
                in
                let churn () =
                  Eio.Promise.await (fst observed.(6).(0));
                  let created =
                    get
                      (C.split_pane controller
                         (Pane.target control_panes.(6))
                         ~direction:Geometry.Right
                         ~spawn:
                           (Spawn.make
                              (Spawn.Exec
                                 { program = "/bin/cat"; args = [ "-u" ] })))
                  in
                  checkpoint
                    ~current:(fun () ->
                      [ ("commands_pending", `Int (pending ())) ])
                    "churn_created"
                    [
                      ("round", `Int round);
                      ( "pane",
                        `String
                          (Pane.Id.to_string (Pane.Target.id created.pane)) );
                    ];
                  get (C.kill_pane controller created.pane);
                  Eio.Promise.await membership_seen;
                  ignore
                    (gap ~discard_data:true membership Output.Membership_changed);
                  let fresh = get (C.capture load) in
                  let pane =
                    Option.get (Snapshot.find_pane fresh (Pane.id panes.(6)))
                  in
                  let replacement = subscribe 6 pane in
                  Eio.Promise.resolve renew replacement;
                  gaps :=
                    json [ ("round", `Int round); ("membership", `Int 2) ]
                    :: !gaps
                in
                let cancel () =
                  Eio.Promise.await (fst observed.(0).(0));
                  let channel = Printf.sprintf "mixed-retained-%d" round in
                  let operation =
                    get (C.submit controller (Operations.wait_for channel))
                  in
                  require
                    (get (O.await_stage operation `Acknowledged)
                    = O.Acknowledged)
                    "retained wait never acknowledged";
                  let seconds = cancel_observer clock operation in
                  require
                    (get (O.inspect operation) = O.Acknowledged)
                    "observer cancellation erased an acknowledged operation";
                  checkpoint
                    ~current:(fun () ->
                      [ ("commands_pending", `Int (pending ())) ])
                    "retained_cancelled"
                    [
                      ("round", `Int round);
                      ("operation", `String (O.id operation));
                    ];
                  get (C.signal controller channel);
                  get (C.await operation);
                  require
                    (get (O.inspect operation) = O.Finished (Ok ()))
                    "retained operation did not finish successfully";
                  retained := operation :: !retained;
                  cancellations :=
                    json
                      [
                        ("round", `Int round);
                        ("operation", `String (O.id operation));
                        ("observer_seconds", `Float seconds);
                        ("retained_outcome", `String "finished_ok");
                      ]
                    :: !cancellations
                in
                let worker id () =
                  Array.iter
                    (fun row ->
                      if row.worker = id then (
                        let outcome = C.await row.operation in
                        require
                          (if row.cancelled then
                             outcome = Error Error.Not_started
                           else outcome = Ok ())
                          "admitted command outcome differs";
                        completions :=
                          json
                            [
                              ("round", `Int round);
                              ("index", `Int row.index);
                              ("worker", `Int id);
                              ("operation", `String (O.id row.operation));
                              ("cancelled_before_write", `Bool row.cancelled);
                              ( "completion_observation",
                                `Int (List.length !completions) );
                              ("seconds", `Float (elapsed clock row.submitted));
                              ( "observed_at_seconds",
                                `Float (elapsed clock started) );
                            ]
                          :: !completions;
                        checkpoint "command_observed"
                          [
                            ("round", `Int round);
                            ("worker", `Int id);
                            ("index", `Int row.index);
                          ]))
                    wave
                in
                Eio.Fiber.all
                  (List.init workers worker @ List.init 7 reader
                 @ List.init 7 sender
                  @ [ churn; cancel; queue_checkpoint ]);
                Array.iteri
                  (fun lane sub ->
                    let lost = Option.get (gap sub Output.Overflow) in
                    gaps :=
                      json
                        [
                          ("round", `Int round);
                          ("lane", `Int lane);
                          ("overflow_lost_bytes", `Int lost);
                        ]
                      :: !gaps)
                  slow;
                checkpoint "round_finished" [ ("round", `Int round) ])
          done;
          checkpoint "validation_started" [];
          let validation_start = Eio.Time.Mono.now clock in
          let validation_count = List.length !requests in
          let attributed =
            List.mapi
              (fun index row ->
                let read_started = Eio.Time.Mono.now clock in
                let value =
                  get
                    (C.read_option load
                       (Options.Session (Session.target (session 0)))
                       row.name)
                in
                require
                  (if row.cancelled then value = None
                   else value = Some (Options.Scalar (Options.Text row.value)))
                  "option value does not match its retained request identity";
                let verified = index + 1 in
                let read_seconds = elapsed clock read_started in
                checkpoint "option_verified"
                  [
                    ("verified", `Int verified);
                    ("total", `Int validation_count);
                    ("operation", `String (O.id row.operation));
                    ("read_seconds", `Float read_seconds);
                  ];
                json
                  [
                    ("operation", `String (O.id row.operation));
                    ("name", `String row.name);
                    ( "observed",
                      match value with
                      | None -> `Null
                      | Some (Options.Scalar (Options.Text text)) ->
                          `String text
                      | _ -> assert false );
                    ( "expected",
                      if row.cancelled then `Null else `String row.value );
                  ])
              !requests
          in
          let validation_seconds = elapsed clock validation_start in
          get (C.close load);
          get (C.close controller);
          List.iter
            (fun row ->
              require
                (if row.cancelled then
                   get (O.inspect row.operation) = O.Not_started
                 else get (O.inspect row.operation) = O.Finished (Ok ()))
                "post-close command outcome changed")
            !requests;
          List.iter
            (fun operation ->
              require
                (get (O.inspect operation) = O.Finished (Ok ()))
                "post-close retained outcome changed")
            !retained;
          checkpoint "clients_closed" [];
          let worker_rows =
            List.init workers (fun worker ->
                let rows =
                  List.filter
                    (fun row ->
                      match row with
                      | `Assoc fields ->
                          List.assoc "worker" fields = `Int worker
                      | _ -> false)
                    !completions
                in
                json
                  [
                    ("worker", `Int worker);
                    ("observations", `Int (List.length rows));
                    ( "successful",
                      `Int
                        (List.length
                           (List.filter
                              (function
                                | `Assoc fields ->
                                    List.assoc "cancelled_before_write" fields
                                    = `Bool false
                                | _ -> false)
                              rows)) );
                  ])
          in
          Yojson.Safe.to_channel stdout
            (json
               [
                 ("event", `String "result");
                 ("completion_observations", `List (List.rev !completions));
                 ("attribution", `List attributed);
                 ("workers", `List worker_rows);
                 ("retained_outcomes_after_close", `Bool true);
                 ("streams", `List (List.rev !streams));
                 ("cancellations", `List (List.rev !cancellations));
                 ("expected_admission_rejections", `List (List.rev !rejections));
                 ("expected_gaps", `List (List.rev !gaps));
                 ("validation_phase_seconds", `Float validation_seconds);
                 ("seconds", `Float (elapsed clock started));
               ]);
          print_newline ()))

let () =
  if Array.length Sys.argv <> 8 then
    failwith
      "usage: mixed TMUX_BINARY SOCKET ROUNDS WORKERS FRAMES PAYLOAD_BYTES";
  let rounds = int_of_string Sys.argv.(3)
  and workers = int_of_string Sys.argv.(4)
  and frames = int_of_string Sys.argv.(5)
  and payload = int_of_string Sys.argv.(6) in
  require (Sys.argv.(7) = "run") "missing explicit benchmark action";
  require
    (rounds >= 1 && rounds <= 6 && workers >= 1 && workers <= 16 && frames >= 2
   && frames <= 12 && payload >= 256 && payload <= 2048)
    "benchmark size outside bounded range";
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          run env sw Sys.argv.(1) Sys.argv.(2) rounds workers frames payload))
