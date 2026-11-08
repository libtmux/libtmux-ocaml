open Libtmux
open Runtime_io
module P = Libtmux__Protocol

module Budget = struct
  type t = { mutable used : int; limit : int }

  let create () = { used = 0; limit = 32 * 1024 * 1024 }

  let reserve t bytes =
    if bytes < 0 || bytes > t.limit - t.used then
      fail (Error.Capacity { resource = "client payload"; limit = t.limit });
    t.used <- t.used + bytes

  let release t bytes = t.used <- t.used - bytes

  let during t bytes f =
    reserve t bytes;
    Fun.protect ~finally:(fun () -> release t bytes) f
end

type lane = {
  mutable io : Runtime_io.t;
  process : Runtime_io.process;
  framer : P.Framer.t;
  events : P.event Queue.t;
  mutable stopped : bool;
  mutable reserved : bool;
}

type t = {
  owner : Domain.id;
  lane : lane;
  pidfd : Unix.file_descr;
  source : Source.t;
  version : string;
  dialect : P.Metadata.dialect;
  budget : Budget.t;
  binary : string;
  timeout : float;
  mutable closed : bool;
  finalize : (unit -> unit) -> unit;
  busy : bool Atomic.t;
  mutable auxiliaries : lane list;
  mutable lane_slots : int;
  mutable cleanup_buffers : string list;
  mutable on_close : unit -> unit;
}

let stop lane =
  if not lane.stopped then (
    lane.stopped <- true;
    Queue.clear lane.events);
  lane.process.stop ()

let owner t = if Domain.self () <> t.owner then fail Error.Wrong_domain

let release_auxiliary t lane =
  Cleanup.protect
    ~finally:(fun () ->
      if lane.reserved then (
        lane.reserved <- false;
        t.lane_slots <- t.lane_slots - 1;
        Budget.release t.budget (2 * 65_536);
        t.auxiliaries <- List.filter (fun item -> item != lane) t.auxiliaries))
    (fun () -> stop lane)

let close t =
  owner t;
  t.closed <- true;
  t.finalize (fun () ->
      Cleanup.run
        ([ t.on_close ]
        @ List.map (fun lane () -> release_auxiliary t lane) t.auxiliaries
        @ [
            (fun () -> t.auxiliaries <- []);
            (fun () -> stop t.lane);
            (fun () -> cleanup_fd t.lane.io.cleanup Close_pidfd t.pidfd);
          ]))

let check t =
  owner t;
  if t.closed then fail Error.Closed;
  if not (Linux.pidfd_alive t.pidfd) then
    Cleanup.protect
      ~finally:(fun () -> close t)
      (fun () -> fail (Error.Disconnected "bound daemon exited"))

let rec event lane ~pidfd ~deadline =
  Runtime_io.check lane.io ~deadline;
  if lane.stopped then fail Error.Closed;
  if Queue.is_empty lane.events then (
    let bytes = Runtime_io.read lane.io lane.process ~pidfd ~deadline in
    let events =
      protocol ~limit:lane.framer.max_frame (P.Framer.feed lane.framer bytes)
    in
    List.iter (fun event -> Queue.add event lane.events) events;
    event lane ~pidfd ~deadline)
  else
    let event = Queue.take lane.events in
    match event with
    | P.Notification text when String.starts_with ~prefix:"%exit" text ->
        fail (Error.Disconnected "tmux detached the control client")
    | _ -> event

let rec startup_frame lane ~deadline ~command =
  match event lane ~pidfd:None ~deadline with
  | P.Frame frame ->
      if not frame.ok then
        fail (Error.Command_failed { command; message = frame.body });
      frame.body
  | P.Notification _ -> startup_frame lane ~deadline ~command
  | P.Diagnostic text -> fail (Error.Malformed_data text)

let first_frame lane ~deadline =
  if startup_frame lane ~deadline ~command:"attach-session" <> "" then
    fail (Error.Malformed_data "unexpected attach output")

let raw lane ~pidfd ~deadline ?(acknowledged = fun () -> ())
    ?(replied = fun _ -> ()) ?(notification = fun _ -> ()) name arguments =
  let marker = "libtmux-ocaml-" ^ Linux.nonce () in
  let command = protocol (P.Command.render name arguments) in
  let ending = protocol (P.Command.render "display-message" [ "-p"; marker ]) in
  let group = P.Group.create ~marker ~count:1 in
  Runtime_io.write lane.io lane.process ~pidfd ~deadline
    (command ^ "\n" ^ ending ^ "\n");
  let rec receive () =
    let item = event lane ~pidfd ~deadline in
    (match item with
    | P.Notification text -> notification text
    | P.Frame frame when group.received = 0 && frame.guard.flags = 1 ->
        if frame.ok then replied frame.body;
        acknowledged ()
    | _ -> ());
    match protocol (P.Group.accept group item) with
    | None -> receive ()
    | Some receipt -> (
        Iarray.iter
          (fun (frame : P.frame) ->
            if (not frame.ok) || frame.body <> "" then
              fail
                (Error.Outcome_unknown
                   ("hook failed or emitted output: "
                   ^ String.sub frame.body 0
                       (min 4096 (String.length frame.body)))))
          receipt.callbacks;
        if receipt.diagnostics <> [] then
          fail (Error.Outcome_unknown (String.concat "\n" receipt.diagnostics));
        match Iarray.get receipt.replies 0 with
        | P.Group.Succeeded body -> body
        | P.Group.Failed message ->
            fail (Error.Command_failed { command = name; message })
        | P.Group.Skipped ->
            fail (Error.Malformed_data "first command was skipped"))
  in
  receive ()

let metadata_raw lane ~pidfd ~deadline ~dialect name arguments fields =
  let template = protocol (P.Metadata.format fields) in
  let body = raw lane ~pidfd ~deadline name (arguments @ [ "-F"; template ]) in
  protocol (P.Metadata.decode ~dialect ~fields:(List.length fields) body)

let singleton rows =
  if Iarray.length rows <> 1 then
    fail (Error.Malformed_data "expected one metadata row");
  Iarray.to_list (Iarray.get rows 0)

let integer text =
  if text = "" || not (String.for_all (fun c -> c >= '0' && c <= '9') text) then
    fail (Error.Malformed_data "expected a nonnegative decimal integer");
  match int_of_string_opt text with
  | Some value -> value
  | None -> fail (Error.Malformed_data "metadata integer overflow")

let boolean = function
  | "0" -> false
  | "1" -> true
  | _ -> fail (Error.Malformed_data "expected a tmux Boolean")

let connect_process ?(timeout = 1.) ~io ~binary ~arguments ~initial endpoint =
  if (not (Float.is_finite timeout)) || timeout <= 0. then
    fail (Error.Invalid_input "timeout must be finite and positive");
  let deadline = Linux.now () +. timeout in
  let lane =
    {
      io;
      process = io.spawn arguments;
      framer = P.Framer.create ();
      events = Queue.create ();
      stopped = false;
      reserved = false;
    }
  in
  let pidfd = ref None in
  try
    initial lane ~deadline;
    let dialect =
      protocol
        (P.Metadata.detect_print
           (raw lane ~pidfd:None ~deadline "display-message"
              [ "-p"; "libtmux\rprobe" ]))
    in
    let identify () =
      let template = protocol (P.Metadata.format [ "pid"; "version" ]) in
      let body =
        raw lane ~pidfd:!pidfd ~deadline "display-message" [ "-p"; template ]
      in
      match
        singleton (protocol (P.Metadata.decode ~dialect ~fields:2 body))
      with
      | [ pid; version ] -> (integer pid, version)
      | _ -> fail (Error.Malformed_data "server identity shape")
    in
    let pid, version = identify () in
    let parsed = protocol (P.Version.parse version) in
    if not (P.Version.supported parsed) then
      fail (Error.Unsupported_version version);
    let descriptor =
      try Linux.pidfd_open pid
      with Unix.Unix_error (error, _, _) ->
        fail (Error.Unsupported_binding (Unix.error_message error))
    in
    pidfd := Some descriptor;
    let fresh_pid, fresh_version = identify () in
    if
      fresh_pid <> pid || fresh_version <> version
      || not (Linux.pidfd_alive descriptor)
    then fail (Error.Disconnected "daemon changed during pidfd acquisition");
    let generation = get (Generation.of_string (Linux.nonce ())) in
    let source = get (Source.create ~endpoint ~generation ~server_pid:pid) in
    {
      owner = Domain.self ();
      lane;
      pidfd = descriptor;
      source;
      version;
      dialect;
      budget = Budget.create ();
      binary;
      timeout;
      closed = false;
      finalize = io.finalizer ();
      busy = Atomic.make false;
      auxiliaries = [];
      lane_slots = 1;
      cleanup_buffers = [];
      on_close = (fun () -> ());
    }
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    Cleanup.protect
      ~finally:(fun () ->
        Cleanup.run
          [
            (fun () -> Option.iter (cleanup_fd io.cleanup Close_pidfd) !pidfd);
            (fun () -> stop lane);
          ])
      (fun () -> Printexc.raise_with_backtrace exn bt)

let connect ?timeout ~io ~binary endpoint =
  connect_process ?timeout ~io ~binary
    ~arguments:(Runtime_io.arguments ~binary endpoint)
    ~initial:first_frame endpoint

let request t ?acknowledged ?replied name arguments =
  check t;
  Budget.during t.budget
    (8 * 1024 * 1024)
    (fun () ->
      try
        raw t.lane ~pidfd:(Some t.pidfd)
          ~deadline:(Linux.now () +. t.timeout)
          ?acknowledged ?replied name arguments
      with
      | Failure (Error.Command_failed _ as error) -> fail error
      | exn ->
          let bt = Printexc.get_raw_backtrace () in
          Cleanup.protect
            ~finally:(fun () -> close t)
            (fun () -> Printexc.raise_with_backtrace exn bt))

let metadata t name arguments fields =
  let template = protocol (P.Metadata.format fields) in
  let bytes = request t name (arguments @ [ "-F"; template ]) in
  protocol
    (P.Metadata.decode ~dialect:t.dialect ~fields:(List.length fields) bytes)

let no_output t ?acknowledged name arguments =
  if request t ?acknowledged name arguments <> "" then
    Cleanup.protect
      ~finally:(fun () -> close t)
      (fun () ->
        fail (Error.Outcome_unknown ("unexpected output from " ^ name)))

let exclusive t f =
  owner t;
  if not (Atomic.compare_and_set t.busy false true) then fail Error.Busy;
  Fun.protect ~finally:(fun () -> Atomic.set t.busy false) f

let target t source =
  owner t;
  if not (Source.equal t.source source) then fail Error.Stale_target

let verify_auxiliary t lane =
  check t;
  let deadline = Linux.now () +. t.timeout in
  first_frame lane ~deadline;
  let template = protocol (P.Metadata.format [ "pid" ]) in
  let body =
    raw lane ~pidfd:(Some t.pidfd) ~deadline "display-message"
      [ "-p"; template ]
  in
  let rows = protocol (P.Metadata.decode ~dialect:t.dialect ~fields:1 body) in
  match singleton rows with
  | [ pid ]
    when integer pid = Source.server_pid t.source && Linux.pidfd_alive t.pidfd
    ->
      ()
  | _ -> fail Error.Stale_target

let open_process t arguments =
  check t;
  if t.lane_slots >= 8 then
    fail (Error.Capacity { resource = "client lanes"; limit = 8 });
  Budget.reserve t.budget (2 * 65_536);
  t.lane_slots <- t.lane_slots + 1;
  match t.lane.io.spawn arguments with
  | process ->
      if t.closed then (
        t.lane_slots <- t.lane_slots - 1;
        Budget.release t.budget (2 * 65_536);
        Cleanup.protect ~finally:process.stop (fun () -> fail Error.Closed));
      let lane =
        {
          io = t.lane.io;
          process;
          framer = P.Framer.create ~max_frame:65_536 ();
          events = Queue.create ();
          stopped = false;
          reserved = true;
        }
      in
      t.auxiliaries <- lane :: t.auxiliaries;
      lane
  | exception exn ->
      t.lane_slots <- t.lane_slots - 1;
      Budget.release t.budget (2 * 65_536);
      raise exn

let with_process t arguments f =
  let lane = open_process t arguments in
  Cleanup.protect
    ~finally:(fun () -> release_auxiliary t lane)
    (fun () -> f lane)

let with_auxiliary t f =
  with_process t
    (Runtime_io.arguments ~binary:t.binary (Source.endpoint t.source))
    (fun lane ->
      (try verify_auxiliary t lane
       with exn ->
         let bt = Printexc.get_raw_backtrace () in
         Cleanup.protect
           ~finally:(fun () -> close t)
           (fun () -> Printexc.raise_with_backtrace exn bt));
      f lane)
