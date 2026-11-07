open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let session_id value = get (Session.Id.of_string value)
let window_id value = get (Window.Id.of_string value)
let pane_id value = get (Pane.Id.of_string value)

let source ?(endpoint = "fixture") ?(generation = 'a') () =
  get
    (Source.create
       ~endpoint:(Endpoint.named_socket endpoint)
       ~generation:(get (Generation.of_string (String.make 64 generation)))
       ~server_pid:123)

let sessions =
  Snapshot.Input.
    [
      { id = session_id "$1"; name = "work"; attached = 1 };
      { id = session_id "$2"; name = "also-work"; attached = 0 };
    ]

let windows =
  Snapshot.Input.
    [
      {
        id = window_id "@1";
        name = "api";
        width = 160;
        height = 48;
        layout = "fixture";
      };
    ]

let links =
  Snapshot.Input.
    [
      {
        session_id = session_id "$1";
        window_id = window_id "@1";
        index = 2;
        is_current = true;
      };
      {
        session_id = session_id "$1";
        window_id = window_id "@1";
        index = 7;
        is_current = false;
      };
      {
        session_id = session_id "$2";
        window_id = window_id "@1";
        index = 0;
        is_current = true;
      };
    ]

let panes =
  Snapshot.Input.
    [
      {
        id = pane_id "%1";
        window_id = window_id "@1";
        index = 0;
        active = true;
        dead = false;
        title = "editor";
        current_command = "nvim";
        current_path = "/srv/project";
        pid = Some 321;
        width = 120;
        height = 48;
        left = 0;
        top = 0;
      };
      {
        id = pane_id "%2";
        window_id = window_id "@1";
        index = 1;
        active = false;
        dead = false;
        title = "shell";
        current_command = "sh";
        current_path = "/tmp";
        pid = Some 322;
        width = 39;
        height = 48;
        left = 121;
        top = 0;
      };
    ]

let make ?(source = source ()) ?(id = 'b') ?(sessions = sessions)
    ?(windows = windows) ?(window_links = links) ?(panes = panes)
    ?(clients = []) () =
  Snapshot.create ~source
    ~id:(get (Snapshot.Id.of_string (String.make 64 id)))
    ~started_at_ns:10L ~finished_at_ns:20L ~sessions ~windows ~window_links
    ~panes ~clients

let snapshot () = get (make ())
