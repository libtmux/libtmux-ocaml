open Libtmux
open Runtime_io
module C = Connection

type hint = {
  session : Session.Id.t;
  window : Window.Id.t;
  pane : Pane.Id.t;
  window_index : int;
  pane_index : int;
  server_pid : int;
}

type state =
  | Queued
  | Admitted
  | Reported of hint
  | Bound of Created.t
  | Rejected of Error.t

type t = { mutable state : state }

let create () = { state = Queued }

let reported body =
  if body = "" || body.[String.length body - 1] <> '\n' then
    fail (Error.Malformed_data "missing bootstrap creation row");
  match
    String.split_on_char '|' (String.sub body 0 (String.length body - 1))
  with
  | [ session; window; pane; window_index; pane_index; pid ] ->
      let id decode value =
        match decode value with
        | Ok id -> id
        | Error _ -> fail (Error.Malformed_data "invalid bootstrap creation ID")
      in
      {
        session = id Session.Id.of_string session;
        window = id Window.Id.of_string window;
        pane = id Pane.Id.of_string pane;
        window_index = C.integer window_index;
        pane_index = C.integer pane_index;
        server_pid = C.integer pid;
      }
  | _ -> fail (Error.Malformed_data "invalid bootstrap creation row")

let start t ?timeout ~io ~binary ~endpoint ~name ~window_name ~spawn ~width
    ~height () =
  if t.state <> Queued then
    fail (Error.Invalid_input "bootstrap was already admitted");
  let flags, args = Command_encoding.spawn spawn in
  let format =
    "#{session_id}|#{window_id}|#{pane_id}|#{window_index}|#{pane_index}|#{pid}"
  in
  let arguments =
    [
      "-E";
      "-f";
      "no-output,ignore-size";
      "-P";
      "-F";
      format;
      "-s";
      Command_encoding.format_text name;
      "-n";
      Command_encoding.format_text window_name;
      "-x";
      Command_encoding.dimension width;
      "-y";
      Command_encoding.dimension height;
    ]
    @ flags @ [ "--" ] @ args
  in
  ignore (protocol (C.P.Command.render "new-session" arguments));
  io.check ();
  let io =
    {
      io with
      spawn =
        (fun args ->
          t.state <- Admitted;
          io.spawn args);
    }
  in
  let initial lane ~deadline =
    let body = C.startup_frame lane ~deadline ~command:"new-session" in
    t.state <- Reported (reported body)
  in
  try
    let connection =
      C.connect_process ?timeout ~io ~binary ~initial
        ~arguments:
          (endpoint_arguments ~start_server:true ~binary endpoint
          @ [ "-C"; "new-session" ] @ arguments)
        endpoint
    in
    try
      let hint =
        match t.state with Reported hint -> hint | _ -> assert false
      in
      if hint.server_pid <> Source.server_pid connection.source then
        fail (Error.Disconnected "bootstrap daemon identity changed");
      let created =
        Created.
          {
            session =
              Session.Target.of_id ~source:connection.source hint.session;
            window = Window.Target.of_id ~source:connection.source hint.window;
            pane = Pane.Target.of_id ~source:connection.source hint.pane;
            window_index = hint.window_index;
            pane_index = hint.pane_index;
          }
      in
      t.state <- Bound created;
      (connection, created)
    with exn ->
      let bt = Printexc.get_raw_backtrace () in
      Cleanup.protect
        ~finally:(fun () -> C.close connection)
        (fun () -> Printexc.raise_with_backtrace exn bt)
  with
  | Failure (Error.Command_failed { command = "new-session"; _ } as cause) ->
    t.state <- Rejected cause;
    fail cause
