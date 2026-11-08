open Libtmux
module C = Libtmux_unix__Connection
module S = Libtmux_unix__Streaming
module Io = Libtmux_unix__Runtime_io

let expect_fault connection manager pane name bytes =
  let sub = S.subscribe ~capacity_bytes:1024 manager pane in
  let lane = Option.get sub.lane in
  let reader, writer = Unix.pipe ~cloexec:true () in
  Unix.set_nonblock reader;
  Unix.dup2 ~cloexec:true reader lane.control.process.output;
  Unix.close reader;
  let sender =
    Domain.spawn (fun () ->
        Fun.protect
          ~finally:(fun () -> Unix.close writer)
          (fun () ->
            let rec write offset =
              if offset < String.length bytes then
                let size =
                  Unix.write_substring writer bytes offset
                    (String.length bytes - offset)
                in
                write (offset + size)
            in
            try write 0 with Unix.Unix_error (Unix.EPIPE, _, _) -> ()))
  in
  Fun.protect
    ~finally:(fun () -> Domain.join sender)
    (fun () ->
      while sub.active do
        let ready, _, _ =
          Unix.select [ lane.control.process.output ] [] [] 0.5
        in
        assert (ready <> []);
        S.poll_lane lane
      done);
  let reason =
    match S.poll sub with
    | Some
        (Output.Gap
           { after = None; lost_bytes = None; reason = Transport_error cause })
      ->
        (match (name, cause) with
        | "eof", Error.Disconnected _ -> ()
        | "oversized", Error.Capacity { limit; _ } ->
            if limit <> 65_536 then
              failwith
                (Printf.sprintf "expected stream limit 65536, got %d" limit)
        | ( ("id" | "escape" | "frame" | "diagnostic" | "truncated"),
            Error.Malformed_data _ ) ->
            ()
        | _ -> failwith (Format.asprintf "%s produced %a" name Error.pp cause));
        Output.Transport_error cause
    | _ -> failwith (name ^ " did not end continuity")
  in
  assert (S.poll sub = Some (Output.End reason));
  assert (S.poll sub = None);
  assert (
    manager.count = 0
    && connection.C.lane_slots = 1
    && connection.budget.used = 0);
  assert (
    C.request connection "display-message" [ "-p"; "primary-alive" ]
    = "primary-alive\n")

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let connection =
    C.connect ~io:(Io.blocking ()) ~binary:Sys.argv.(1)
      (Endpoint.socket_path Sys.argv.(2))
  in
  Fun.protect
    ~finally:(fun () -> C.close connection)
    (fun () ->
      let manager = S.create ~changed:(fun () -> ()) connection in
      let pane =
        Iarray.get
          (Snapshot.panes (Libtmux_unix__Acquisition.snapshot connection))
          0
      in
      List.iter
        (fun (name, bytes) -> expect_fault connection manager pane name bytes)
        [
          ("id", "%output not-a-pane x\n");
          ("escape", "%output %0 \\777\n");
          ("frame", "%begin 1 1 1\nx\n%end 1 1 1\n");
          ("diagnostic", "unexpected output\n");
          ("truncated", "%output %0 \\00");
          ("eof", "");
          ("oversized", String.make 65_537 'x');
        ];
      print_endline
        "PASS stream faults, reserved terminal events, budget release and \
         primary isolation")
