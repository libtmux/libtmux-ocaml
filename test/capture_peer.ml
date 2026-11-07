open Libtmux
module C = Libtmux_unix.Client
module Internal = Libtmux_unix__Connection
module Io = Libtmux_unix__Runtime_io

let get = function
  | Ok value -> value
  | Error e -> failwith (Format.asprintf "%a" Error.pp e)

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  let client = get (C.connect ~binary endpoint) in
  Fun.protect
    ~finally:(fun () -> ignore (get (C.close client)))
    (fun () ->
      let snapshot = get (C.capture client) in
      let pane =
        Option.get (Snapshot.find_pane snapshot (get (Pane.Id.of_string "%1")))
      in
      match Sys.argv.(3) with
      | "capture" ->
          let result = get (C.capture_text client pane ~start:0 ~end_:2) in
          assert (result.bytes = "%end 1 1 1\nhello\n\n");
          assert (Source.equal result.source (Snapshot.source snapshot));
          assert (result.finished_at_ns >= result.started_at_ns);
          assert (
            match
              C.capture_text client pane ~start:0 ~end_:(Pane.height pane)
            with
            | Error (Error.Invalid_input _) -> true
            | _ -> false)
      | "hooks" ->
          assert (
            match C.capture_text client pane ~start:0 ~end_:2 with
            | Error Error.Unsupported_capture_hooks -> true
            | _ -> false)
      | "save-error" ->
          let internal = Internal.connect ~io:Io.blocking ~binary endpoint in
          Fun.protect
            ~finally:(fun () -> Internal.close internal)
            (fun () ->
              let file = Libtmux_unix__Capture_file.create "/tmp" in
              Fun.protect
                ~finally:(fun () -> Libtmux_unix__Capture_file.cleanup file)
                (fun () ->
                  let result =
                    Io.protect (fun () ->
                        Internal.no_output internal "save-buffer"
                          [ "-b"; "unrelated"; file.directory ])
                  in
                  assert (
                    match result with
                    | Error (Error.Outcome_unknown _) -> true
                    | _ -> false);
                  assert internal.closed))
      | _ -> assert false);
  print_endline "PASS capture"
