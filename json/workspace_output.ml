open Libtmux
open Document
module P = Libtmux_workspace.Plan
module X = Libtmux_workspace.Execution

let limit = 4_194_304

let charge budget bytes =
  if bytes > limit - !budget then
    fail "" Decode_error.Limit "workspace output exceeds 4 MiB";
  budget := !budget + bytes

let text budget value : Yojson.Safe.t =
  if String.is_valid_utf_8 value then (
    charge budget (string_cost value);
    `String value)
  else (
    charge budget (64 + (2 * String.length value));
    let digits = "0123456789abcdef" in
    let bytes =
      String.init
        (2 * String.length value)
        (fun i ->
          let byte = Char.code value.[i / 2] in
          digits.[if i mod 2 = 0 then byte lsr 4 else byte land 15])
    in
    `Assoc [ ("encoding", `String "hex"); ("bytes", `String bytes) ])

let object_ budget values =
  charge budget (2 + (64 * List.length values));
  `Assoc values

let array budget values =
  charge budget (2 + List.length values);
  `List values

let option f = function None -> `Null | Some value -> f value
let int value = `Int value

let endpoint budget value =
  let kind, value =
    match Endpoint.kind value with
    | Named_socket value -> ("named_socket", value)
    | Socket_path value -> ("socket_path", value)
  in
  object_ budget [ ("kind", text budget kind); ("value", text budget value) ]

let source budget value =
  object_ budget
    [
      ("endpoint", endpoint budget (Source.endpoint value));
      ("server_pid", int (Source.server_pid value));
      ( "generation",
        text budget (Generation.to_string (Source.generation value)) );
    ]

let bounded value =
  if String.length value <= 4096 then (value, false)
  else (String.sub value 0 4096, true)

let error budget value =
  let code, message, attributes =
    match value with
    | Error.Invalid_input message -> ("invalid_input", message, [])
    | Malformed_data message -> ("malformed_data", message, [])
    | Capture_raced message -> ("capture_raced", message, [])
    | Unsupported_version message -> ("unsupported_version", message, [])
    | Unsupported_binding message -> ("unsupported_binding", message, [])
    | Unsupported_capture_hooks ->
        ("unsupported_capture_hooks", "capture hooks are unsupported", [])
    | Unsupported message -> ("unsupported", message, [])
    | Closed -> ("closed", "client is closed", [])
    | Disconnected message -> ("disconnected", message, [])
    | Filesystem { operation; message } ->
        let operation, _ = bounded operation in
        ("filesystem", message, [ ("operation", text budget operation) ])
    | Wrong_domain -> ("wrong_domain", "handle belongs to another domain", [])
    | Busy -> ("busy", "another operation is active", [])
    | Capacity { resource; limit } ->
        let resource, _ = bounded resource in
        ( "capacity",
          "capacity limit exceeded",
          [ ("resource", text budget resource); ("limit", int limit) ] )
    | Stale_target -> ("stale_target", "target generation changed", [])
    | No_such_entity { kind; id } ->
        let kind, _ = bounded kind and id, _ = bounded id in
        ( "no_such_entity",
          "target is absent",
          [ ("kind", text budget kind); ("id", text budget id) ] )
    | Command_failed { command; message } ->
        let command, _ = bounded command in
        ("command_failed", message, [ ("operation", text budget command) ])
    | Deadline_exceeded -> ("deadline_exceeded", "deadline exceeded", [])
    | Not_started -> ("not_started", "command was not admitted", [])
    | Outcome_unknown message -> ("outcome_unknown", message, [])
  in
  let message, truncated = bounded message in
  object_ budget
    ([
       ("code", text budget code);
       ("message", text budget message);
       ("message_truncated", `Bool truncated);
     ]
    @ attributes)

let layout = function
  | Layout.Even_horizontal -> "even-horizontal"
  | Even_vertical -> "even-vertical"
  | Main_horizontal -> "main-horizontal"
  | Main_vertical -> "main-vertical"
  | Tiled -> "tiled"
  | Custom value -> value

let direction = function
  | Geometry.Left -> "left"
  | Right -> "right"
  | Above -> "above"
  | Below -> "below"

let size budget = function
  | Geometry.Cells value -> object_ budget [ ("cells", int value) ]
  | Percent value -> object_ budget [ ("percent", int value) ]

let spawn budget value =
  let command =
    match value.Spawn.command with
    | Default -> [ ("command", `String "default") ]
    | Shell value -> [ ("shell", text budget value) ]
    | Exec { program; args } ->
        [ ("exec", array budget (List.map (text budget) (program :: args))) ]
  in
  object_ budget
    (command
    @ [
        ("cwd", option (text budget) value.cwd);
        ( "environment_names",
          array budget
            (List.map (fun (name, _) -> text budget name) value.environment) );
      ])

let scope budget = function
  | P.Session -> object_ budget [ ("kind", `String "session") ]
  | Window wi ->
      object_ budget [ ("kind", `String "window"); ("window", int wi) ]
  | Pane { window; pane } ->
      object_ budget
        [ ("kind", `String "pane"); ("window", int window); ("pane", int pane) ]

let action budget ~details value =
  let indices wi pi = [ ("window", int wi); ("pane", int pi) ] in
  let extra f = if details then f () else [] in
  let kind, fields =
    match value with
    | P.Create_session
        { bootstrap; name; window_name; spawn = command; width; height } ->
        ( "create_session",
          extra (fun () ->
              [
                ("bootstrap", `Bool bootstrap);
                ("name", text budget name);
                ("window_name", text budget window_name);
                ("spawn", spawn budget command);
                ("width", int width);
                ("height", int height);
              ]) )
    | Create_window { window; name; spawn = command } ->
        ( "create_window",
          ("window", int window)
          :: extra (fun () ->
              [ ("name", text budget name); ("spawn", spawn budget command) ])
        )
    | Split_pane
        { window; pane; spawn = command; direction = side; size = extent } ->
        ( "split_pane",
          indices window pane
          @ extra (fun () ->
              [
                ("spawn", spawn budget command);
                ("direction", text budget (direction side));
                ("size", option (size budget) extent);
              ]) )
    | Set_environment (name, _) ->
        ("set_environment", extra (fun () -> [ ("name", text budget name) ]))
    | Set_option (target, setting) ->
        ( "set_option",
          [ ("scope", scope budget target) ]
          @ extra (fun () ->
              [
                ("name", text budget setting.name);
                ("index", option int setting.index);
              ]) )
    | Send_text { window; pane; text = value } ->
        ( "send_text",
          indices window pane
          @ extra (fun () -> [ ("bytes", int (String.length value)) ]) )
    | Send_enter { window; pane } -> ("send_enter", indices window pane)
    | Select_layout (window, value) ->
        ( "select_layout",
          ("window", int window)
          :: extra (fun () -> [ ("layout", text budget (layout value)) ]) )
  in
  object_ budget (("kind", text budget kind) :: fields)

let created budget (value : Created.t) =
  object_ budget
    [
      ( "session",
        text budget (Session.Id.to_string (Session.Target.id value.session)) );
      ( "window",
        text budget (Window.Id.to_string (Window.Target.id value.window)) );
      ("pane", text budget (Pane.Id.to_string (Pane.Target.id value.pane)));
      ("window_index", int value.window_index);
      ("pane_index", int value.pane_index);
    ]

let hint budget (value : X.hint) =
  object_ budget
    [
      ("session", text budget (Session.Id.to_string value.session));
      ("window", text budget (Window.Id.to_string value.window));
      ("pane", text budget (Pane.Id.to_string value.pane));
      ("window_index", int value.window_index);
      ("pane_index", int value.pane_index);
      ("server_pid", int value.server_pid);
    ]

let plan value =
  protect (fun () ->
      let budget = ref 0 in
      object_ budget
        [
          ("schema", `String "libtmux.workspace-plan/1");
          ("advisory", `Bool true);
          ("endpoint", endpoint budget (P.endpoint value));
          ("source", option (source budget) (P.source value));
          ( "session",
            text budget (Libtmux_workspace.Config.session (P.config value)) );
          ( "actions",
            P.actions value |> Iarray.to_list
            |> List.mapi (fun index value ->
                object_ budget
                  [
                    ("index", int index);
                    ("action", action budget ~details:true value);
                  ])
            |> array budget );
        ])

let status = function
  | X.Queued -> "queued"
  | Applying -> "applying"
  | Succeeded -> "succeeded"
  | Partial -> "partial"
  | Interrupted -> "interrupted"
  | Rejected _ -> "rejected"
  | Unavailable _ -> "unavailable"

let plan_error budget value =
  let code, message =
    match value with
    | P.Missing_endpoint -> ("missing_endpoint", "required endpoint is absent")
    | Session_conflict _ -> ("session_conflict", "session name already exists")
    | Window_conflict _ -> ("window_conflict", "window name already exists")
    | Append_session_options ->
        ("append_session_options", "append cannot set session options")
    | Too_many_steps -> ("too_many_steps", "workspace plan exceeds 4096 actions")
    | Unsupported_setting value -> ("unsupported_setting", value.message)
    | Stale -> ("stale", "plan generation or captured preconditions changed")
  in
  let message, truncated = bounded message in
  object_ budget
    [
      ("code", text budget code);
      ("message", text budget message);
      ("message_truncated", `Bool truncated);
    ]

let receipt (value : X.receipt) =
  protect (fun () ->
      let budget = ref 0 in
      let completed = ref []
      and failed = ref []
      and skipped = ref []
      and uncertain = ref []
      and pending = ref [] in
      let steps =
        value.steps |> Iarray.to_list
        |> List.map (fun (step : X.step) ->
            let status, cause, category =
              match step.status with
              | Pending -> ("pending", `Null, pending)
              | Running -> ("running", `Null, uncertain)
              | Completed -> ("completed", `Null, completed)
              | Skipped -> ("skipped", `Null, skipped)
              | Failed cause -> ("failed", error budget cause, failed)
              | Uncertain cause -> ("uncertain", error budget cause, uncertain)
            in
            category := int step.index :: !category;
            object_ budget
              [
                ("index", int step.index);
                ("action", action budget ~details:false step.action);
                ("status", text budget status);
                ("error", cause);
                ( "created",
                  array budget (List.map (created budget) step.created) );
                ("unbound", option (hint budget) step.unbound);
              ])
      in
      let cause =
        match value.status with
        | Rejected cause -> plan_error budget cause
        | Unavailable cause -> error budget cause
        | _ -> `Null
      in
      object_ budget
        [
          ("schema", `String "libtmux.workspace-receipt/1");
          ("operation_id", text budget value.operation_id);
          ("source", option (source budget) value.source);
          ("status", text budget (status value.status));
          ("error", cause);
          ("completed", array budget (List.rev !completed));
          ("failed", array budget (List.rev !failed));
          ("skipped", array budget (List.rev !skipped));
          ("uncertain", array budget (List.rev !uncertain));
          ("pending", array budget (List.rev !pending));
          ("steps", array budget steps);
          ( "cleanup",
            value.cleanup |> Iarray.to_list
            |> List.map (fun (entry : X.cleanup) ->
                object_ budget
                  [
                    ( "pane",
                      text budget
                        (Pane.Id.to_string (Pane.Target.id entry.pane)) );
                    ( "error",
                      match entry.outcome with
                      | Ok () -> `Null
                      | Error cause -> error budget cause );
                  ])
            |> array budget );
          ("cleanup_error", option (error budget) value.cleanup_error);
        ])
