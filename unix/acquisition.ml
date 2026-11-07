open Libtmux
open Runtime_io
open Connection

let map rows f =
  Iarray.to_list rows |> List.map (fun row -> f (Iarray.to_list row))

let shape () = fail (Error.Malformed_data "unexpected metadata row shape")

let snapshot client =
  Budget.during client.budget
    (16 * 1024 * 1024)
    (fun () ->
      let started_at_ns = Linux.monotonic_ns () in
      let sessions =
        metadata client "list-sessions" []
          [ "session_id"; "session_name"; "session_attached" ]
        |> fun rows ->
        map rows (function
          | [ id; name; attached ] ->
              Snapshot.Input.
                {
                  id = get (Session.Id.of_string id);
                  name;
                  attached = integer attached;
                }
          | _ -> shape ())
      in
      let window_rows =
        metadata client "list-windows" [ "-a" ]
          [
            "window_id";
            "window_name";
            "window_width";
            "window_height";
            "window_layout";
            "session_id";
            "window_index";
            "window_active";
          ]
      in
      let windows, window_links =
        map window_rows (function
          | [ id; name; width; height; layout; session; index; active ] ->
              let id = get (Window.Id.of_string id) in
              ( Snapshot.Input.
                  {
                    id;
                    name;
                    width = integer width;
                    height = integer height;
                    layout;
                  },
                Snapshot.Input.
                  {
                    session_id = get (Session.Id.of_string session);
                    window_id = id;
                    index = integer index;
                    is_current = boolean active;
                  } )
          | _ -> shape ())
        |> List.split
      in
      let panes =
        metadata client "list-panes" [ "-a" ]
          [
            "pane_id";
            "window_id";
            "pane_index";
            "pane_active";
            "pane_dead";
            "pane_title";
            "pane_current_command";
            "pane_current_path";
            "pane_pid";
            "pane_width";
            "pane_height";
            "pane_left";
            "pane_top";
          ]
        |> fun rows ->
        map rows (function
          | [
              id;
              window;
              index;
              active;
              dead;
              title;
              current_command;
              current_path;
              pid;
              width;
              height;
              left;
              top;
            ] ->
              Snapshot.Input.
                {
                  id = get (Pane.Id.of_string id);
                  window_id = get (Window.Id.of_string window);
                  index = integer index;
                  active = boolean active;
                  dead = boolean dead;
                  title;
                  current_command;
                  current_path;
                  pid =
                    (if pid = "" || pid = "0" then None else Some (integer pid));
                  width = integer width;
                  height = integer height;
                  left = integer left;
                  top = integer top;
                }
          | _ -> shape ())
      in
      let clients =
        metadata client "list-clients" []
          [
            "client_name";
            "session_id";
            "client_pid";
            "client_width";
            "client_height";
            "client_control_mode";
          ]
        |> fun rows ->
        map rows (function
          | [ name; session; pid; width; height; control ] ->
              Snapshot.Input.
                {
                  name;
                  session_id =
                    (if session = "" then None
                     else Some (get (Session.Id.of_string session)));
                  pid = integer pid;
                  width = integer width;
                  height = (if height = "" then None else Some (integer height));
                  control_mode = boolean control;
                }
          | _ -> shape ())
      in
      check client;
      get
        (Snapshot.create ~source:client.source
           ~id:(get (Snapshot.Id.of_string (Linux.nonce ())))
           ~started_at_ns ~finished_at_ns:(Linux.monotonic_ns ()) ~sessions
           ~windows ~window_links ~panes ~clients))
