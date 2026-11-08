open Libtmux
open Runtime_io
module C = Connection

type cleanup_receipt = {
  cause : Error.t;
  owned_buffers : string list;
  created : Created.t list;
}

type 'a state =
  | Queued
  | Not_started
  | Written
  | Acknowledged
  | Finished of ('a, Error.t) result
  | Outcome_unknown of cleanup_receipt

type t = {
  connection : C.t;
  mutable queue : packed list;
  mutable active : packed list;
  mutable admitted : int;
  mutable bytes : int;
  mutable sequence : int;
  changed : unit -> unit;
}

and 'a operation = {
  client : t;
  command : 'a Command.t;
  wire : (string * string list) option;
  id : string;
  bytes : int;
  mutable state : 'a state;
  mutable released : bool;
  mutable created : Created.t list;
}

and packed = Pack : 'a operation -> packed

let create ?(changed = fun () -> ()) connection =
  {
    connection;
    queue = [];
    active = [];
    admitted = 0;
    bytes = 0;
    sequence = 0;
    changed;
  }

let set op state =
  op.state <- state;
  op.client.changed ()

let release op =
  if not op.released then (
    op.released <- true;
    op.client.admitted <- op.client.admitted - 1;
    op.client.bytes <- op.client.bytes - op.bytes;
    C.Budget.release op.client.connection.budget op.bytes)

let cancel op =
  C.owner op.client.connection;
  match op.state with
  | Queued ->
      op.client.queue <-
        List.filter (fun (Pack other) -> other.id <> op.id) op.client.queue;
      release op;
      set op Not_started
  | Not_started | Written | Acknowledged | Finished _ | Outcome_unknown _ -> ()

let inspect op =
  C.owner op.client.connection;
  op.state

let id op = op.id

let key = function
  | Key.Enter -> "Enter"
  | Tab -> "Tab"
  | Escape -> "Escape"
  | Backspace -> "BSpace"
  | Up -> "Up"
  | Down -> "Down"
  | Left -> "Left"
  | Right -> "Right"
  | Control c when c >= 'a' && c <= 'z' -> "C-" ^ String.make 1 c
  | Control _ ->
      fail (Error.Invalid_input "control keys require a lowercase ASCII letter")

let prepare : type a. C.t -> a Command.t -> (string * string list) option =
 fun connection command ->
  let pane target =
    C.target connection (Pane.Target.source target);
    Pane.Id.to_string (Pane.Target.id target)
  in
  match Command.view command with
  | Capture -> None
  | Capture_environment (scope, hidden) ->
      Some
        ( "show-environment",
          Command_encoding.environment_scope connection scope
          @ [ "-s" ]
          @ if hidden then [ "-h" ] else [] )
  | Capture_options (scope, include_inherited) ->
      ignore (get (Options.catalog ~version:connection.version));
      Some
        ( "show-options",
          Command_encoding.option_scope connection scope
          @ if include_inherited then [ "-A" ] else [] )
  | Read_option (scope, name, include_inherited) ->
      ignore (Command_encoding.option_descriptor connection scope name);
      Some
        ( "show-options",
          Command_encoding.option_scope connection scope
          @ (if include_inherited then [ "-A" ] else [])
          @ [ "--"; name ] )
  | Capture_hooks scope ->
      ignore (get (Options.catalog ~version:connection.version));
      (match scope with
      | Options.Server ->
          fail (Error.Invalid_input "hooks have no server option scope")
      | _ -> ());
      Some ("show-hooks", Command_encoding.option_scope connection scope)
  | Read_hook (scope, name, include_inherited) ->
      ignore
        (Command_encoding.option_descriptor ~hook:true connection scope name);
      Some
        ( "show-options",
          Command_encoding.option_scope connection scope
          @ (if include_inherited then [ "-A" ] else [])
          @ [ "--"; name ] )
  | Capture_text { pane; start; end_; scratch_dir } ->
      C.target connection (Pane.source pane);
      if start < 0 || end_ < start || end_ >= Pane.height pane then
        fail
          (Error.Invalid_input
             "capture rows must lie within the observed screen");
      if end_ - start + 1 > 1_000_000 / Pane.width pane then
        fail (Error.Capacity { resource = "capture cells"; limit = 1_000_000 });
      Capture_file.validate_root scratch_dir;
      None
  | Rename_window (target, name) ->
      C.target connection (Window.Target.source target);
      Some
        ( "rename-window",
          [
            "-t";
            Window.Id.to_string (Window.Target.id target);
            Command_encoding.format_text name;
          ] )
  | Rename_session (target, name) ->
      C.target connection (Session.Target.source target);
      Some
        ( "rename-session",
          [
            "-t";
            Session.Id.to_string (Session.Target.id target);
            Command_encoding.format_text name;
          ] )
  | Send_text (target, text) ->
      Some ("send-keys", [ "-t"; pane target; "-l"; "--"; text ])
  | Send_keys (target, keys) ->
      let rec bounded count = function
        | [] -> ()
        | _ :: rest ->
            if count = 65_536 then
              fail (Error.Capacity { resource = "keys"; limit = 65_536 });
            bounded (count + 1) rest
      in
      bounded 0 keys;
      Some ("send-keys", [ "-t"; pane target; "--" ] @ List.map key keys)
  | Wait_for channel | Signal channel ->
      if channel = "" then
        fail (Error.Invalid_input "wait channel must be nonempty");
      let args =
        match Command.view command with
        | Signal _ -> [ "-S"; channel ]
        | _ -> [ channel ]
      in
      Some ("wait-for", args)
  | Mutate command -> Some (Command_encoding.mutation connection command)
  | (Create_session _ | Create_window _ | Split_pane _ | Break_pane _) as
    creation ->
      Some (Command_encoding.create connection creation)

let admit client command =
  C.owner client.connection;
  if client.connection.closed then fail Error.Closed;
  let wire = prepare client.connection command in
  let bytes =
    match wire with
    | None -> 512
    | Some (name, args) -> (
        ignore
          (List.fold_left
             (fun size arg ->
               if String.length arg > 1_048_576 - size then
                 fail
                   (Error.Capacity
                      { resource = "command bytes"; limit = 1_048_576 });
               size + String.length arg)
             0 args);
        match C.P.Command.render name args with
        | Ok text -> String.length text + 160
        | Error (C.P.Malformed message) -> fail (Error.Invalid_input message)
        | Error (C.P.Limit _) ->
            fail
              (Error.Capacity
                 { resource = "encoded command bytes"; limit = 1_048_576 }))
  in
  if client.admitted >= 64 then
    fail (Error.Capacity { resource = "admitted commands"; limit = 64 });
  if bytes > 1_048_576 - client.bytes then
    fail
      (Error.Capacity { resource = "queued command bytes"; limit = 1_048_576 });
  C.Budget.reserve client.connection.budget bytes;
  client.sequence <- client.sequence + 1;
  let op =
    {
      client;
      command;
      wire;
      id =
        Generation.to_string (Source.generation client.connection.source)
        ^ ":"
        ^ Int.to_string client.sequence;
      bytes;
      state = Queued;
      released = false;
      created = [];
    }
  in
  client.admitted <- client.admitted + 1;
  client.bytes <- client.bytes + bytes;
  client.queue <- client.queue @ [ Pack op ];
  client.changed ();
  op

let submit client command =
  C.owner client.connection;
  if client.connection.closed then fail Error.Closed;
  if client.admitted >= 64 then
    fail (Error.Capacity { resource = "admitted commands"; limit = 64 });
  C.Budget.during client.connection.budget
    (2 * 1024 * 1024)
    (fun () -> admit client command)

let finish op result =
  (match op.state with
  | Finished _ | Not_started | Outcome_unknown _ -> ()
  | Queued -> set op (Finished result)
  | Written | Acknowledged -> (
      match result with
      | Error cause
        when op.client.connection.closed
             ||
             match cause with
             | Error.Disconnected _ | Error.Outcome_unknown _
             | Error.Deadline_exceeded | Error.Closed ->
                 true
             | _ -> false ->
          set op
            (Outcome_unknown
               {
                 cause;
                 owned_buffers = op.client.connection.cleanup_buffers;
                 created = op.created;
               })
      | result -> set op (Finished result)));
  release op

let execute : type a. a operation -> a =
 fun op ->
  let c = op.client.connection in
  C.check c;
  set op Written;
  let acknowledged () = set op Acknowledged in
  let action () =
    let name, args = Option.get op.wire in
    C.no_output c ~acknowledged name args
  in
  let creation () =
    let name, args = Option.get op.wire in
    let replied body = op.created <- [ Command_encoding.created c body ] in
    ignore (C.request c ~acknowledged ~replied name args);
    match op.created with
    | [ created ] -> created
    | _ -> fail (Error.Malformed_data "missing creation receipt")
  in
  match Command.view op.command with
  | Capture -> Acquisition.snapshot c
  | Capture_environment (scope, hidden) ->
      let _, arguments = Option.get op.wire in
      Environment_io.capture c scope hidden arguments
  | Capture_options (scope, include_inherited) ->
      let _, arguments = Option.get op.wire in
      Options_io.capture c scope include_inherited arguments
  | Read_option (_, name, _) ->
      let _, arguments = Option.get op.wire in
      Options_io.read c name arguments
  | Capture_hooks scope ->
      let _, arguments = Option.get op.wire in
      Options_io.capture ~hooks:true c scope false arguments
  | Read_hook (_, name, _) ->
      let _, arguments = Option.get op.wire in
      Options_io.read c name arguments
  | Capture_text { pane; start; end_; scratch_dir } ->
      Rendered.capture ~scratch_dir c pane ~start ~end_
  | Wait_for channel ->
      C.with_auxiliary c (fun lane ->
          let body =
            C.raw lane ~pidfd:(Some c.pidfd)
              ~deadline:(Linux.now () +. c.timeout)
              ~acknowledged "wait-for" [ channel ]
          in
          if body <> "" then
            fail (Error.Outcome_unknown "unexpected wait output"))
  | Rename_window _ -> action ()
  | Rename_session _ -> action ()
  | Send_text _ -> action ()
  | Send_keys _ -> action ()
  | Signal _ -> action ()
  | Mutate _ -> action ()
  | Create_session _ -> creation ()
  | Create_window _ -> creation ()
  | Split_pane _ -> creation ()
  | Break_pane _ -> creation ()

let take client =
  match client.queue with
  | [] -> None
  | job :: rest ->
      client.queue <- rest;
      client.active <- job :: client.active;
      Some job

let retire ?(cause = Error.Closed) client =
  C.owner client.connection;
  client.connection.closed <- true;
  List.iter (fun (Pack op) -> cancel op) client.queue;
  List.iter (fun (Pack op) -> finish op (Error cause)) client.active

let close ?(cause = Error.Closed) client =
  retire ~cause client;
  Cleanup.run
    [
      (fun () -> C.close client.connection);
      (fun () ->
        Cleanup.step client.connection.lane.io.cleanup Notify_waiters
          client.changed);
    ]

let run (Pack op) =
  Fun.protect
    ~finally:(fun () ->
      op.client.active <-
        List.filter (fun (Pack other) -> other.id <> op.id) op.client.active)
    (fun () ->
      match protect (fun () -> execute op) with
      | result -> finish op result
      | exception exn ->
          let bt = Printexc.get_raw_backtrace () in
          finish op
            (Error (Error.Outcome_unknown "operation owner interrupted"));
          Cleanup.protect
            ~finally:(fun () -> close op.client)
            (fun () -> Printexc.raise_with_backtrace exn bt))

let result op =
  C.owner op.client.connection;
  match op.state with
  | Finished result -> Some result
  | Not_started -> Some (Error Error.Not_started)
  | Outcome_unknown receipt ->
      Some
        (Error
           (Error.Outcome_unknown (Format.asprintf "%a" Error.pp receipt.cause)))
  | _ -> None

let await_owned op =
  C.owner op.client.connection;
  let rec pump () =
    match result op with
    | Some result -> get result
    | None -> (
        match take op.client with
        | None -> fail Error.Busy
        | Some job ->
            run job;
            pump ())
  in
  pump ()

let await op = C.exclusive op.client.connection (fun () -> await_owned op)
