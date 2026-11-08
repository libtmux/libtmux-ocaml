open Libtmux
open Runtime_io
module C = Connection
module P = Libtmux__Protocol

type serial = { run : 'a. (unit -> 'a) -> 'a }

type t = {
  connection : C.t;
  changed : unit -> unit;
  mutable make_serial : unit -> serial;
  mutable started : lane -> unit;
  mutable lanes : lane list;
  mutable count : int;
}

and lane = {
  manager : t;
  session : Session.Id.t;
  control : C.lane;
  serial : serial;
  mutable subscribers : subscription list;
  mutable pending : int;
  mutable retired : bool;
}

and subscription = {
  manager : t;
  pane : Pane.Id.t;
  window : Window.Id.t;
  session : Session.Id.t;
  generation : Generation.t;
  capacity_bytes : int;
  capacity_events : int;
  queue : Output.event Queue.t;
  mutable lane : lane option;
  mutable active : bool;
  mutable bytes : int;
  mutable offset : int64;
  mutable delivered : Output.cursor option;
}

let reclaim lane =
  if (not lane.retired) && lane.pending = 0 && lane.subscribers = [] then (
    lane.retired <- true;
    lane.manager.lanes <- List.filter (( != ) lane) lane.manager.lanes;
    C.release_auxiliary lane.manager.connection lane.control)

let finish ?(gap = false) ?lost_bytes sub reason =
  if sub.active then (
    sub.active <- false;
    sub.manager.count <- sub.manager.count - 1;
    C.Budget.release sub.manager.connection.budget sub.capacity_bytes;
    Queue.clear sub.queue;
    sub.bytes <- 0;
    if gap then
      Queue.add
        (Output.Gap { after = sub.delivered; lost_bytes; reason })
        sub.queue;
    Queue.add (Output.End reason) sub.queue;
    Cleanup.protect
      ~finally:(fun () ->
        Cleanup.step sub.manager.connection.lane.io.cleanup Notify_waiters
          sub.manager.changed)
      (fun () ->
        Option.iter
          (fun lane ->
            lane.subscribers <- List.filter (( != ) sub) lane.subscribers;
            reclaim lane)
          sub.lane))

let retire lane reason =
  List.iter (fun sub -> finish ~gap:true sub reason) lane.subscribers;
  if not lane.retired then (
    lane.retired <- true;
    lane.manager.lanes <- List.filter (( != ) lane) lane.manager.lanes;
    C.release_auxiliary lane.manager.connection lane.control)

let close_all manager reason =
  Cleanup.run (List.map (fun lane () -> retire lane reason) manager.lanes)

let create ~changed connection =
  let manager =
    {
      connection;
      changed;
      make_serial = (fun () -> { run = (fun f -> f ()) });
      started = (fun _ -> ());
      lanes = [];
      count = 0;
    }
  in
  let previous = connection.C.on_close in
  connection.on_close <-
    (fun () ->
      Cleanup.run
        [
          (fun () -> close_all manager (Output.Transport_error Error.Closed));
          previous;
        ]);
  manager

let push sub bytes =
  if sub.active && bytes <> "" then
    let length = String.length bytes in
    if
      length > sub.capacity_bytes - sub.bytes
      || Queue.length sub.queue >= sub.capacity_events
      || Int64.sub Int64.max_int sub.offset < Int64.of_int length
    then finish ~gap:true ~lost_bytes:(sub.bytes + length) sub Output.Overflow
    else (
      sub.offset <- Int64.add sub.offset (Int64.of_int length);
      sub.bytes <- sub.bytes + length;
      let cursor =
        Output.{ generation = sub.generation; offset = sub.offset }
      in
      Queue.add (Output.Data { cursor; bytes }) sub.queue;
      sub.manager.changed ())

let split text =
  match String.index_opt text ' ' with
  | None -> (text, "")
  | Some position ->
      ( String.sub text 0 position,
        String.sub text (position + 1) (String.length text - position - 1) )

let structural window text =
  let name, rest = split text in
  let id, _ = split rest in
  List.mem name
    [
      "%layout-change";
      "%window-close";
      "%unlinked-window-close";
      "%window-add";
      "%unlinked-window-add";
    ]
  && id = Window.Id.to_string window

let notification lane text =
  let name, rest = split text in
  let id, body = split rest in
  if name = "%output" then
    let pane =
      match Pane.Id.of_string id with
      | Ok pane -> pane
      | Error _ ->
          fail (Error.Malformed_data "invalid pane ID in stream output")
    in
    let bytes = protocol (P.Output.decode body) in
    List.iter
      (fun sub -> if Pane.Id.equal sub.pane pane then push sub bytes)
      lane.subscribers
  else if name = "%pause" || name = "%continue" || name = "%extended-output"
  then
    List.iter
      (fun sub ->
        if Pane.Id.to_string sub.pane = id then
          finish ~gap:true sub Output.Server_paused)
      lane.subscribers
  else if name = "%session-changed" then (
    if id <> Session.Id.to_string lane.session then
      retire lane Output.Membership_changed)
  else if name = "%exit" then
    retire lane
      (Output.Transport_error (Error.Disconnected "stream client detached"))
  else
    List.iter
      (fun sub ->
        if
          structural sub.window text
          || (name = "%pane-mode-changed" && id = Pane.Id.to_string sub.pane)
        then finish ~gap:true sub Output.Membership_changed)
      lane.subscribers

let accept lane = function
  | P.Notification text -> notification lane text
  | P.Diagnostic _ | P.Frame _ ->
      fail (Error.Malformed_data "unexpected reply on an idle stream lane")

let drain_events lane =
  while (not lane.retired) && not (Queue.is_empty lane.control.events) do
    accept lane (Queue.take lane.control.events)
  done

let poll_lane lane =
  if not lane.retired then
    lane.serial.run (fun () ->
        if not lane.retired then
          match
            protect (fun () ->
                C.check lane.manager.connection;
                drain_events lane;
                if not lane.retired then
                  let chunk = Bytes.create 65_536 in
                  let read fd =
                    try Unix.read fd chunk 0 (Bytes.length chunk)
                    with
                    | Unix.Unix_error
                        ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
                    ->
                      -1
                  in
                  let count = read lane.control.process.output in
                  if count = 0 then (
                    ignore
                      (protocol ~limit:lane.control.framer.max_frame
                         (P.Framer.finish lane.control.framer));
                    fail (Error.Disconnected "stream client exited"))
                  else if count > 0 then
                    protocol ~limit:lane.control.framer.max_frame
                      (P.Framer.feed lane.control.framer
                         (Bytes.sub_string chunk 0 count))
                    |> List.iter (fun event ->
                        if not lane.retired then accept lane event)
                  else if read lane.control.process.error > 0 then
                    fail
                      (Error.Disconnected "stream client reported a diagnostic"))
          with
          | Ok () -> ()
          | Error error -> retire lane (Output.Transport_error error))

let pump manager =
  C.owner manager.connection;
  List.iter poll_lane manager.lanes

let selected_session pane requested =
  let links = Window.links (Pane.window pane) |> Iarray.to_seq in
  let sessions =
    links
    |> Seq.map (fun link -> Session.id (Window_link.session link))
    |> List.of_seq
  in
  match requested with
  | Some target ->
      if not (Source.equal (Session.Target.source target) (Pane.source pane))
      then fail Error.Stale_target;
      let id = Session.Target.id target in
      if not (List.exists (Session.Id.equal id) sessions) then
        fail
          (Error.Invalid_input
             "selected session does not cover the observed pane");
      id
  | None -> (
      match List.sort_uniq Session.Id.compare sessions with
      | first :: _ -> first
      | [] -> fail (Error.Capture_raced "pane has no observed session link"))

let open_lane manager session =
  let c = manager.connection in
  let arguments =
    Runtime_io.arguments ~binary:c.binary (Source.endpoint c.source)
  in
  let control = C.open_process c arguments in
  try
    (try C.verify_auxiliary c control
     with exn ->
       let bt = Printexc.get_raw_backtrace () in
       Cleanup.protect
         ~finally:(fun () -> C.close c)
         (fun () -> Printexc.raise_with_backtrace exn bt));
    let lane =
      {
        manager;
        session;
        control;
        serial = manager.make_serial ();
        subscribers = [];
        pending = 0;
        retired = false;
      }
    in
    List.iter
      (fun (command, arguments) ->
        let body =
          C.raw control ~pidfd:(Some c.pidfd)
            ~deadline:(Linux.now () +. c.timeout)
            command arguments
        in
        if body <> "" then
          fail (Error.Malformed_data "unexpected stream attachment output"))
      [
        ("refresh-client", [ "-f"; "no-output,ignore-size" ]);
        ("switch-client", [ "-E"; "-t"; Session.Id.to_string session ]);
      ];
    manager.lanes <- lane :: manager.lanes;
    lane
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    Cleanup.protect
      ~finally:(fun () -> C.release_auxiliary c control)
      (fun () -> Printexc.raise_with_backtrace exn bt)

let subscribe ?session ?(capacity_bytes = 1_048_576) ?(capacity_events = 1024)
    manager pane =
  let c = manager.connection in
  C.check c;
  C.target c (Pane.source pane);
  if
    capacity_bytes < 1 || capacity_bytes > 1_048_576 || capacity_events < 1
    || capacity_events > 1024
  then
    fail
      (Error.Invalid_input
         "subscription limits must be within 1..1048576 bytes and 1..1024 \
          events");
  if manager.count = 16 then
    fail (Error.Capacity { resource = "subscriptions"; limit = 16 });
  let session = selected_session pane session in
  let generation = get (Generation.of_string (Linux.nonce ())) in
  C.Budget.reserve c.budget capacity_bytes;
  manager.count <- manager.count + 1;
  let sub =
    {
      manager;
      pane = Pane.id pane;
      window = Window.id (Pane.window pane);
      session;
      generation;
      capacity_bytes;
      capacity_events;
      queue = Queue.create ();
      lane = None;
      active = true;
      bytes = 0;
      offset = 0L;
      delivered = None;
    }
  in
  try
    let lane, fresh =
      match
        List.find_opt
          (fun lane ->
            (not lane.retired) && Session.Id.equal lane.session session)
          manager.lanes
      with
      | Some lane -> (lane, false)
      | None -> (open_lane manager session, true)
    in
    sub.lane <- Some lane;
    lane.pending <- lane.pending + 1;
    Cleanup.protect
      ~finally:(fun () ->
        lane.pending <- lane.pending - 1;
        reclaim lane)
      (fun () ->
        lane.serial.run (fun () ->
            if lane.retired then
              fail
                (Error.Capture_raced
                   "subscription lane retired during admission");
            let changed = ref false in
            let notify text =
              if structural sub.window text then changed := true;
              notification lane text
            in
            let raw name args =
              C.raw lane.control ~pidfd:(Some c.pidfd)
                ~deadline:(Linux.now () +. c.timeout)
                ~notification:notify name args
            in
            let target =
              Session.Id.to_string session
              ^ ":"
              ^ Window.Id.to_string sub.window
              ^ "." ^ Pane.Id.to_string sub.pane
            in
            let fields = [ "session_id"; "window_id"; "pane_id" ] in
            let template = protocol (P.Metadata.format fields) in
            let body = raw "display-message" [ "-p"; "-t"; target; template ] in
            let values =
              C.singleton
                (protocol (P.Metadata.decode ~dialect:c.dialect ~fields:3 body))
            in
            if
              values
              <> [
                   Session.Id.to_string session;
                   Window.Id.to_string sub.window;
                   Pane.Id.to_string sub.pane;
                 ]
            then
              fail
                (Error.Capture_raced
                   "pane no longer belongs to the selected session/window");
            if fresh && raw "refresh-client" [ "-f"; "!no-output" ] <> "" then
              fail (Error.Malformed_data "unexpected stream activation output");
            if !changed || lane.retired then
              fail
                (Error.Capture_raced "pane coverage changed during admission");
            lane.subscribers <- sub :: lane.subscribers));
    if fresh then manager.started lane;
    sub
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    Cleanup.protect
      ~finally:(fun () ->
        Cleanup.run
          [
            (fun () ->
              Option.iter
                (fun lane ->
                  retire lane
                    (Output.Transport_error
                       (Error.Disconnected "stream admission interrupted")))
                sub.lane);
            (fun () -> finish sub Output.Cancelled);
          ])
      (fun () -> Printexc.raise_with_backtrace exn bt)

let poll (sub : subscription) =
  C.owner sub.manager.connection;
  match Queue.take_opt sub.queue with
  | Some (Output.Data { cursor; bytes } as event) ->
      sub.bytes <- sub.bytes - String.length bytes;
      sub.delivered <- Some cursor;
      Some event
  | other -> other

let close (sub : subscription) =
  C.owner sub.manager.connection;
  finish sub Output.Cancelled

let descriptors manager =
  List.concat_map
    (fun lane -> [ lane.control.process.output; lane.control.process.error ])
    manager.lanes

let next ?cancel ~timeout (sub : subscription) =
  let c = sub.manager.connection in
  if (not (Float.is_finite timeout)) || timeout <= 0. then
    fail
      (Error.Invalid_input "subscription timeout must be finite and positive");
  C.owner c;
  let deadline = Linux.now () +. timeout in
  let run cancel_fd =
    let rec loop () =
      if Option.exists Cancellation.is_cancelled cancel then (
        close sub;
        raise Cancellation.Cancelled);
      if Linux.now () >= deadline then fail Error.Deadline_exceeded;
      match poll sub with
      | Some event -> Some event
      | None when not sub.active -> None
      | None ->
          pump sub.manager;
          if Queue.is_empty sub.queue && sub.active then
            Runtime_io.wait
              ~read:
                ((c.pidfd :: Option.to_list cancel_fd) @ descriptors sub.manager)
              ~write:[] ~deadline;
          loop ()
    in
    loop ()
  in
  match cancel with
  | None -> run None
  | Some token -> (
      try Cancellation.borrow token (fun fd -> run (Some fd))
      with Cancellation.Cancelled as exn ->
        let bt = Printexc.get_raw_backtrace () in
        Cleanup.protect
          ~finally:(fun () -> close sub)
          (fun () -> Printexc.raise_with_backtrace exn bt))

let wait_for_bytes ~next ~timeout (sub : subscription) ~text =
  match
    protect (fun () ->
        C.owner sub.manager.connection;
        Byte_pattern.validate text;
        if (not (Float.is_finite timeout)) || timeout <= 0. then
          fail (Error.Invalid_input "wait timeout must be finite and positive");
        C.Budget.during sub.manager.connection.budget
          (9 * String.length text)
          (fun () ->
            let pattern = Byte_pattern.create text in
            let deadline = Linux.now () +. timeout in
            let rec loop () =
              let remaining = deadline -. Linux.now () in
              if remaining <= 0. then
                Error (Output.Failure Error.Deadline_exceeded)
              else
                match next remaining with
                | Error error -> Error (Output.Failure error)
                | Ok (Some (Output.Data { cursor; bytes })) -> (
                    match Byte_pattern.feed pattern bytes with
                    | None -> loop ()
                    | Some index ->
                        Ok
                          Output.
                            {
                              cursor with
                              offset =
                                Int64.sub cursor.offset
                                  (Int64.of_int
                                     (String.length bytes - index - 1));
                            })
                | Ok (Some (Gap { reason; _ } | End reason)) ->
                    Error (Output.Ended reason)
                | Ok None -> Error (Output.Ended Output.Cancelled)
            in
            loop ()))
  with
  | Ok result -> result
  | Error error -> Error (Output.Failure error)
