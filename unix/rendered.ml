open Libtmux
open Runtime_io
open Connection

type t = Captured_text.t = {
  bytes : string;
  source : Source.t;
  pane : Pane.Id.t;
  started_at_ns : int64;
  finished_at_ns : int64;
}

let check_hooks client pane =
  let hooks =
    [
      "after-capture-pane";
      "after-save-buffer";
      "after-list-buffers";
      "after-display-message";
      "after-show-options";
    ]
  in
  List.iter
    (fun arguments ->
      (* show-hooks prints command arguments through args_escape, including
         newlines. An unindexed array format would hide nonzero hook indexes. *)
      let body = request client "show-hooks" arguments in
      String.split_on_char '\n' body
      |> List.iter (fun line ->
          if
            List.exists
              (fun hook -> String.starts_with ~prefix:(hook ^ "[") line)
              hooks
          then fail Error.Unsupported_capture_hooks))
    [
      [ "-g" ];
      [ "-gw" ];
      [];
      [ "-w" ];
      [ "-p" ];
      [ "-t"; pane ];
      [ "-w"; "-t"; pane ];
      [ "-p"; "-t"; pane ];
    ]

let capture ?(scratch_dir = "/tmp") client pane ~start ~end_ =
  target client (Pane.source pane);
  let width = Pane.width pane in
  if start < 0 || end_ < start || end_ >= Pane.height pane then
    fail
      (Error.Invalid_input "capture rows must lie within the observed screen");
  if end_ - start + 1 > 1_000_000 / width then
    fail (Error.Capacity { resource = "capture cells"; limit = 1_000_000 });
  let id = Pane.Id.to_string (Pane.id pane) in
  check_hooks client id;
  Budget.during client.budget
    (16 * 1024 * 1024)
    (fun () ->
      let file_io = client.lane.io.file_io in
      let file = file_io (fun () -> Capture_file.create scratch_dir) in
      let file_cleaned = ref false in
      Fun.protect
        ~finally:(fun () ->
          if not !file_cleaned then
            file_io (fun () -> Capture_file.cleanup file))
        (fun () ->
          let buffer = "libtmux-ocaml-" ^ Linux.nonce () in
          client.cleanup_buffers <- buffer :: client.cleanup_buffers;
          let forget () =
            client.cleanup_buffers <-
              List.filter (( <> ) buffer) client.cleanup_buffers
          in
          let created = ref false in
          let cleanup () =
            Fun.protect
              ~finally:(fun () ->
                file_cleaned := true;
                file_io (fun () -> Capture_file.cleanup file))
              (fun () ->
                if !created && not client.closed then (
                  no_output client "delete-buffer" [ "-b"; buffer ];
                  forget ()))
          in
          let started_at_ns = Linux.monotonic_ns () in
          let outcome =
            protect (fun () ->
                created := true;
                no_output client "capture-pane"
                  [
                    "-b";
                    buffer;
                    "-t";
                    id;
                    "-S";
                    Int.to_string start;
                    "-E";
                    Int.to_string end_;
                  ];
                let rows =
                  metadata client "list-buffers"
                    [ "-f"; "#{==:#{buffer_name}," ^ buffer ^ "}" ]
                    [ "buffer_name"; "buffer_size" ]
                in
                let size =
                  match Iarray.to_list rows with
                  | [ row ] -> (
                      match Iarray.to_list row with
                      | [ name; size ] when name = buffer -> integer size
                      | _ ->
                          fail
                            (Error.Capture_raced
                               "capture buffer metadata changed"))
                  | _ ->
                      created := false;
                      forget ();
                      fail (Error.Capture_raced "capture buffer is absent")
                in
                if size > Capture_file.max_bytes then
                  fail
                    (Error.Capacity
                       {
                         resource = "capture buffer";
                         limit = Capture_file.max_bytes;
                       });
                no_output client "save-buffer" [ "-b"; buffer; file.path ];
                let bytes =
                  file_io (fun () -> Capture_file.read file ~expected:size)
                in
                {
                  bytes;
                  source = client.source;
                  pane = Pane.id pane;
                  started_at_ns;
                  finished_at_ns = Linux.monotonic_ns ();
                })
          in
          let cleaned = protect cleanup in
          match (outcome, cleaned) with
          | Ok value, Ok () -> value
          | Error error, Ok () when not client.closed -> fail error
          | Error error, Ok () ->
              fail
                (Error.Outcome_unknown
                   (Format.asprintf "%a; unresolved owned buffer %s" Error.pp
                      error buffer))
          | _, Error error ->
              fail
                (Error.Outcome_unknown
                   (Format.asprintf "capture cleanup: %a; owned buffer %s"
                      Error.pp error buffer))))
