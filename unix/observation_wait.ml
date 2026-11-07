open Libtmux
open Runtime_io

let rec coalesce ~poll event =
  match event with
  | Some (Output.Data _) -> (
      match poll () with None -> event | next -> coalesce ~poll next)
  | Some (Gap _ | End _) | None -> event

let rendered ~connection ~capture ~capture_text ~subscribe ~next ~poll ~close
    ~timeout pane ~text =
  Connection.owner connection;
  Connection.target connection (Pane.source pane);
  Byte_pattern.validate text;
  if (not (Float.is_finite timeout)) || timeout <= 0. then
    fail (Error.Invalid_input "wait timeout must be finite and positive");
  Connection.Budget.during connection.budget
    (9 * String.length text)
    (fun () ->
      let pattern = Byte_pattern.create text in
      let deadline = Linux.now () +. timeout in
      let check () =
        if Linux.now () >= deadline then fail Error.Deadline_exceeded
      in
      let fresh () =
        check ();
        let snapshot = get (capture ()) in
        match Snapshot.find_pane snapshot (Pane.id pane) with
        | Some pane -> pane
        | None ->
            fail
              (Error.No_such_entity
                 { kind = "pane"; id = Pane.Id.to_string (Pane.id pane) })
      in
      let current = ref pane and active = ref None in
      Fun.protect
        ~finally:(fun () -> Option.iter (fun sub -> ignore (close sub)) !active)
        (fun () ->
          let attach () =
            check ();
            active := Some (get (subscribe !current))
          in
          attach ();
          let rec observe () =
            check ();
            let text = get (capture_text !current) in
            check ();
            if Byte_pattern.contains pattern text.Captured_text.bytes then text
            else
              let sub = Option.get !active in
              match
                coalesce
                  ~poll:(fun () -> get (poll sub))
                  (get (next (deadline -. Linux.now ()) sub))
              with
              | Some (Output.Data _) ->
                  current := fresh ();
                  observe ()
              | Some (Gap { reason = Membership_changed | Overflow; _ }) ->
                  ignore (close sub);
                  active := None;
                  current := fresh ();
                  attach ();
                  observe ()
              | Some (Gap { reason; _ } | End reason) ->
                  fail
                    (Error.Disconnected
                       (Format.asprintf "%a" Output.reason_pp reason))
              | None -> fail Error.Closed
          in
          observe ()))
