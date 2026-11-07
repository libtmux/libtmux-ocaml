open Libtmux
module C = Libtmux_eio.Client
module W = Libtmux_eio.Workspace
module P = Libtmux_workspace.Plan
module X = Libtmux_workspace.Execution
module J = Libtmux_json

exception Interrupted
exception Stop of int * Yojson.Safe.t

let object_ values = `Assoc values
let text value = `String value

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

let stop code error =
  raise
    (Stop
       ( code,
         object_
           [ ("schema", text "libtmux.workspace-error/1"); ("error", error) ] ))

let native error = stop 6 (J.Error.encode error)

let decode_error error =
  stop 2
    (object_
       [
         ("code", text "invalid_document");
         ("pointer", text error.J.Decode_error.pointer);
         ("message", text error.message);
       ])

let get = function Ok value -> value | Error error -> native error
let decoded = function Ok value -> value | Error error -> decode_error error

let plan_error error =
  let code =
    match error with
    | P.Missing_endpoint -> 3
    | Session_conflict _ | Window_conflict _ | Append_session_options | Stale ->
        4
    | Too_many_steps | Unsupported_setting _ -> 6
  in
  stop code
    (object_
       [
         ("code", text "plan_rejected");
         ("message", text (Format.asprintf "%a" P.pp_error error));
       ])

let install_interrupt ~sw ~seen scope =
  let reader, writer = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock reader;
  Unix.set_nonblock writer;
  let previous =
    Sys.signal Sys.sigint
      (Sys.Signal_handle
         (fun _ ->
           seen := true;
           try ignore (Unix.write_substring writer "x" 0 1)
           with Unix.Unix_error ((Unix.EAGAIN | EWOULDBLOCK | EINTR), _, _) ->
             ()))
  in
  Eio.Switch.on_release sw (fun () ->
      Sys.set_signal Sys.sigint previous;
      Unix.close writer;
      Unix.close reader);
  Eio.Fiber.fork_daemon ~sw (fun () ->
      Eio_unix.await_readable reader;
      ignore (Unix.read reader (Bytes.create 64) 0 64);
      Eio.Cancel.cancel scope Interrupted;
      `Stop_daemon)

let with_deadline mono_clock seconds f =
  Eio.Fiber.first f (fun () ->
      Eio.Time.Mono.sleep mono_clock seconds;
      native Error.Deadline_exceeded)

let load fs path =
  let path = absolute path in
  let raw =
    try
      Eio.Path.with_open_in
        Eio.Path.(fs / path)
        (fun flow ->
          Eio.Buf_read.of_flow ~max_size:65_537 flow |> Eio.Buf_read.take_all)
    with
    | Eio.Buf_read.Buffer_limit_exceeded ->
        decode_error
          J.Decode_error.
            {
              pointer = "";
              category = Limit;
              message = "document exceeds 64 KiB";
            }
    | Eio.Io _ ->
        stop 2
          (object_
             [
               ("code", text "document_read_failed");
               ("message", text "cannot read workspace document");
             ])
  in
  let config =
    decoded (J.Workspace.of_string ~directory:(Filename.dirname path) raw)
  in
  let digest = Digest.BLAKE256.(to_hex (string raw)) in
  (config, digest)

let exists fs path =
  try
    let stat = Eio.Path.stat ~follow:true Eio.Path.(fs / path) in
    if stat.kind <> `Socket then
      stop 2
        (object_
           [
             ("code", text "invalid_endpoint");
             ("message", text "endpoint exists and is not a socket");
           ]);
    true
  with Eio.Io (Eio.Fs.E (Not_found _), _) -> false

let local_version ~process_mgr ~mono_clock ~fs ~binary ~timeout =
  with_deadline mono_clock timeout (fun () ->
      Eio.Switch.run (fun child_sw ->
          let output, stdout = Eio.Process.pipe ~sw:child_sw process_mgr in
          let stderr =
            Eio.Path.open_out ~sw:child_sw ~create:`Never
              Eio.Path.(fs / "/dev/null")
          in
          let env =
            Eio.Process.environment process_mgr
            |> Eio.Process.Env.override [ ("TMUX", None); ("TMUX_PANE", None) ]
          in
          let child =
            Eio.Process.spawn ~sw:child_sw process_mgr ~stdout ~stderr ~env
              [ binary; "-V" ]
          in
          Eio.Flow.close stdout;
          let reply =
            try
              Eio.Buf_read.of_flow ~max_size:256 output |> Eio.Buf_read.take_all
            with Eio.Buf_read.Buffer_limit_exceeded ->
              native
                (Error.Malformed_data "tmux version response exceeds 256 bytes")
          in
          Eio.Flow.close output;
          (match Eio.Process.await child with
          | `Exited 0 -> ()
          | _ -> native (Error.Malformed_data "tmux -V failed"));
          let reply = String.trim reply in
          if not (String.starts_with ~prefix:"tmux " reply) then
            native (Error.Malformed_data "invalid tmux version response");
          let version = String.sub reply 5 (String.length reply - 5) in
          let module V = Libtmux__Protocol.Version in
          (match V.parse version with
          | Ok parsed when V.supported parsed -> ()
          | Ok _ -> native (Error.Unsupported_version version)
          | Error _ ->
              native (Error.Malformed_data "invalid tmux version response"));
          version))

let add_digest digest = function
  | `Assoc fields ->
      `Assoc (("document_digest", text ("blake2b-256:" ^ digest)) :: fields)
  | _ -> invalid_arg "workspace output must be an object"

let receipt_exit (receipt : X.receipt) =
  match receipt.status with
  | Succeeded -> 0
  | Rejected Missing_endpoint -> 3
  | Rejected
      (Session_conflict _ | Window_conflict _ | Append_session_options | Stale)
    ->
      4
  | Rejected (Too_many_steps | Unsupported_setting _) | Unavailable _ -> 6
  | Queued | Applying | Partial -> 5
  | Interrupted -> 130

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string = function
  | `String value -> value
  | value -> Yojson.Safe.to_string value

let human document =
  match member "schema" document with
  | Some (`String "libtmux.workspace-plan/1") ->
      let actions =
        match member "actions" document with
        | Some (`List values) -> values
        | _ -> []
      in
      let header =
        Printf.sprintf "Advisory plan: %d action%s" (List.length actions)
          (if List.length actions = 1 then "" else "s")
      in
      let rows =
        List.map
          (fun action ->
            let index =
              Option.get (member "index" action) |> Yojson.Safe.Util.to_int
            in
            let action = Option.get (member "action" action) in
            let kind = Option.get (member "kind" action) |> string in
            let name =
              match member "name" action with
              | None -> ""
              | Some value -> " " ^ Printf.sprintf "%S" (string value)
            in
            Printf.sprintf "%d. %s%s" index
              (String.replace_all ~sub:"_" ~by:" " kind)
              name)
          actions
      in
      let endpoint =
        Option.get (member "endpoint" document)
        |> member "value" |> Option.get |> string
      in
      String.concat "\n"
        (header :: Printf.sprintf "endpoint: %S" endpoint :: rows)
      ^ "\n"
  | Some (`String "libtmux.workspace-receipt/1") ->
      let list name value =
        match member name value with Some (`List values) -> values | _ -> []
      in
      let count name = List.length (list name document) in
      let summary =
        Printf.sprintf "%s: %d completed, %d failed, %d skipped, %d uncertain"
          (string (Option.get (member "status" document)))
          (count "completed") (count "failed") (count "skipped")
          (count "uncertain")
      in
      let describe_error = function
        | `Null -> ""
        | error ->
            let code = Option.get (member "code" error) |> string in
            let message = Option.get (member "message" error) |> string in
            Printf.sprintf "%s: %S" code message
      in
      let details =
        List.concat_map
          (fun step ->
            let index =
              Option.get (member "index" step) |> Yojson.Safe.Util.to_int
            in
            let action = Option.get (member "action" step) in
            let kind =
              Option.get (member "kind" action)
              |> string
              |> String.replace_all ~sub:"_" ~by:" "
            in
            let error =
              match member "error" step with
              | Some error -> describe_error error
              | None -> ""
            in
            let failed =
              if error = "" then []
              else [ Printf.sprintf "step %d %s: %s" index kind error ]
            in
            let unbound =
              match member "unbound" step with
              | None | Some `Null -> []
              | Some hint ->
                  [
                    Printf.sprintf
                      "step %d unbound creation hint: daemon %d, session %s, \
                       window %s, pane %s"
                      index
                      (Yojson.Safe.Util.to_int
                         (Option.get (member "server_pid" hint)))
                      (string (Option.get (member "session" hint)))
                      (string (Option.get (member "window" hint)))
                      (string (Option.get (member "pane" hint)));
                  ]
            in
            failed @ unbound
            @ List.map
                (fun value ->
                  Printf.sprintf "step %d %s: session %s, window %s, pane %s"
                    index kind
                    (string (Option.get (member "session" value)))
                    (string (Option.get (member "window" value)))
                    (string (Option.get (member "pane" value))))
                (list "created" step))
          (list "steps" document)
      in
      let cleanup = list "cleanup" document in
      let failed_cleanup =
        List.filter (fun item -> member "error" item <> Some `Null) cleanup
      in
      let cleanup_summary =
        if cleanup = [] then []
        else
          [
            Printf.sprintf "cleanup: %d succeeded, %d failed"
              (List.length cleanup - List.length failed_cleanup)
              (List.length failed_cleanup);
          ]
      in
      let cleanup_details =
        List.map
          (fun item ->
            Printf.sprintf "cleanup pane %s: %s"
              (string (Option.get (member "pane" item)))
              (describe_error (Option.get (member "error" item))))
          failed_cleanup
      in
      let general_error =
        List.filter_map
          (fun name ->
            match member name document with
            | None | Some `Null -> None
            | Some error -> Some (name ^ ": " ^ describe_error error))
          [ "error"; "cleanup_error" ]
      in
      String.concat "\n"
        ([
           summary;
           "operation: " ^ string (Option.get (member "operation_id" document));
         ]
        @ details @ cleanup_summary @ cleanup_details @ general_error)
      ^ "\n"
  | Some (`String "libtmux.workspace-check/1") ->
      Printf.sprintf "Valid workspace %S: %d windows, %d panes\n"
        (string (Option.get (member "session" document)))
        (Yojson.Safe.Util.to_int (Option.get (member "windows" document)))
        (Yojson.Safe.Util.to_int (Option.get (member "panes" document)))
  | _ -> Yojson.Safe.pretty_to_string document ^ "\n"

let run ~command ~json ~file ~socket ~binary ~timeout ~require_existing ~append
    ~keep_partial ~expect_document =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let retained = ref None
          and digest = ref None
          and interrupt_seen = ref false in
          let output ~code document =
            let document =
              match !digest with
              | None -> document
              | Some value -> add_digest value document
            in
            let bytes =
              if json then Yojson.Safe.to_string document ^ "\n"
              else human document
            in
            let sink =
              if code = 0 || json then Eio.Stdenv.stdout env
              else Eio.Stdenv.stderr env
            in
            let delivered =
              try
                Eio.Cancel.protect (fun () ->
                    Eio.Fiber.first
                      (fun () ->
                        Eio.Flow.copy_string bytes sink;
                        true)
                      (fun () ->
                        Eio.Time.Mono.sleep (Eio.Stdenv.mono_clock env) 0.5;
                        false))
              with Eio.Io _ -> false
            in
            if !interrupt_seen then 130
            else if delivered || code = 130 then code
            else 6
          in
          try
            Eio.Cancel.sub (fun scope ->
                install_interrupt ~sw ~seen:interrupt_seen scope;
                let fs = Eio.Stdenv.fs env in
                if (not (Float.is_finite timeout)) || timeout <= 0. then
                  stop 2
                    (object_
                       [
                         ("code", text "invalid_timeout");
                         ("message", text "timeout must be finite and positive");
                       ]);
                let config, actual_digest = load fs file in
                digest := Some actual_digest;
                (match expect_document with
                | Some expected when expected <> "blake2b-256:" ^ actual_digest
                  ->
                    stop 4
                      (object_
                         [
                           ("code", text "document_changed");
                           ( "message",
                             text "workspace document differs from the preview"
                           );
                         ])
                | _ -> ());
                let code, document =
                  if command = `Check then
                    let windows = Libtmux_workspace.Config.windows config in
                    ( 0,
                      object_
                        [
                          ("schema", text "libtmux.workspace-check/1");
                          ( "session",
                            text (Libtmux_workspace.Config.session config) );
                          ("windows", `Int (Iarray.length windows));
                          ( "panes",
                            `Int
                              (Iarray.fold_left
                                 (fun count
                                      (w : Libtmux_workspace.Config.window) ->
                                   count + List.length w.panes)
                                 0 windows) );
                        ] )
                  else
                    let socket =
                      match socket with
                      | Some value -> absolute value
                      | None ->
                          stop 2
                            (object_
                               [
                                 ("code", text "missing_endpoint");
                                 ( "message",
                                   text
                                     "supply --socket with an explicit socket \
                                      path" );
                               ])
                    in
                    let endpoint =
                      try Endpoint.socket_path socket
                      with Invalid_argument _ ->
                        stop 2
                          (object_
                             [
                               ("code", text "invalid_endpoint");
                               ("message", text "invalid socket path");
                             ])
                    in
                    let client, version, observed =
                      if exists fs socket then (
                        let client =
                          get
                            (C.connect ~binary ~timeout ~sw
                               ~process_mgr:(Eio.Stdenv.process_mgr env)
                               ~mono_clock:(Eio.Stdenv.mono_clock env)
                               endpoint)
                        in
                        Eio.Switch.on_release sw (fun () ->
                            ignore (C.close client));
                        ( Some client,
                          C.version client,
                          Some (get (C.capture client)) ))
                      else if require_existing then
                        plan_error P.Missing_endpoint
                      else
                        ( None,
                          local_version
                            ~process_mgr:(Eio.Stdenv.process_mgr env)
                            ~mono_clock:(Eio.Stdenv.mono_clock env)
                            ~fs ~binary ~timeout,
                          None )
                    in
                    let plan =
                      match
                        P.make ~endpoint ~version ~observed
                          ~server_policy:
                            (if require_existing then Require_existing_server
                             else Create_if_missing)
                          ~collision_policy:
                            (if append then
                               Append_new_windows { window_collision = Reject }
                             else Fail_if_session_exists)
                          config
                      with
                      | Ok value -> value
                      | Error error -> plan_error error
                    in
                    if command = `Plan then
                      (0, decoded (J.Workspace.encode_plan plan))
                    else
                      let operation =
                        get
                          (match client with
                          | Some client -> W.submit client plan
                          | None ->
                              W.submit_bootstrap ~binary ~timeout ~sw
                                ~process_mgr:(Eio.Stdenv.process_mgr env)
                                ~mono_clock:(Eio.Stdenv.mono_clock env)
                                plan)
                      in
                      retained := Some operation;
                      Eio.Switch.on_release sw (fun () ->
                          ignore (W.close operation));
                      let receipt =
                        get
                          (W.await ~compensate_on_failure:(not keep_partial)
                             operation)
                      in
                      ( receipt_exit receipt,
                        decoded (J.Workspace.encode_receipt receipt) )
                in
                Eio.Fiber.yield ();
                output ~code document)
          with
          | Stop (code, document) -> output ~code document
          | Eio.Cancel.Cancelled Interrupted ->
              let document =
                match !retained with
                | Some operation ->
                    get (W.inspect operation)
                    |> J.Workspace.encode_receipt |> decoded
                | None ->
                    object_
                      [
                        ("schema", text "libtmux.workspace-error/1");
                        ("error", J.Error.encode Error.Not_started);
                      ]
              in
              output ~code:130 document
          | Eio.Io _ ->
              output ~code:6
                (object_
                   [
                     ("schema", text "libtmux.workspace-error/1");
                     ("error", J.Error.encode (Error.Disconnected "I/O failed"));
                   ])))
