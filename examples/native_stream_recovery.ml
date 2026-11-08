open Libtmux
module Client = Libtmux_eio.Client
module Subscription = Libtmux_eio.Subscription

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let protect ~finally use =
  match use () with
  | value ->
      Eio.Cancel.protect finally;
      value
  | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      (try Eio.Cancel.protect finally
       with cleanup ->
         Format.eprintf "cleanup failed: %s@." (Printexc.to_string cleanup));
      Printexc.raise_with_backtrace error backtrace

let with_subscription client pane use =
  let subscription = get (Client.subscribe client pane) in
  protect
    ~finally:(fun () -> get (Subscription.close subscription))
    (fun () -> use subscription)

let echo client pane subscription text =
  let cursor, () =
    Eio.Fiber.pair
      (fun () ->
        match Subscription.wait_for_bytes ~timeout:0.5 subscription ~text with
        | Ok cursor -> cursor
        | Error (Output.Failure error) ->
            failwith (Format.asprintf "%a" Error.pp error)
        | Error (Output.Ended reason) ->
            failwith (Format.asprintf "%a" Output.reason_pp reason))
      (fun () ->
        get (Client.send_text client (Pane.target pane) ~text);
        get (Client.send_keys client (Pane.target pane) [ Key.Enter ]))
  in
  cursor

let observe_gap ~clock subscription =
  let rec next () =
    match get (Subscription.next subscription) with
    | Some (Output.Data _) -> next ()
    | Some (Output.Gap { reason = Membership_changed; _ }) ->
        print_endline "gap=membership-changed; history=unavailable"
    | Some (Output.Gap { reason; _ } | Output.End reason) ->
        failwith (Format.asprintf "unexpected end: %a" Output.reason_pp reason)
    | None -> failwith "subscription ended before its gap"
  in
  Eio.Time.Timeout.run_exn (Eio.Time.Timeout.seconds clock 0.5) next

let capture_pane client id =
  match Snapshot.find_pane (get (Client.capture client)) id with
  | Some pane -> pane
  | None -> failwith "pane disappeared; choose a target explicitly"

(* docs:begin recover-coverage *)
let recover_coverage client id (previous : Output.cursor) =
  let fresh = capture_pane client id in
  let after =
    with_subscription client fresh (fun subscription ->
        echo client fresh subscription "after-gap")
  in
  if Generation.equal previous.generation after.generation then
    failwith "new subscription reused the old cursor generation";
  print_endline "coverage=fresh; cursor-generation=new; future=after-gap"
(* docs:end recover-coverage *)

let recover ~clock client session =
  let spawn = Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] }) in
  let created =
    get (Client.create_window client session ~name:"stream-recovery" ~spawn)
  in
  protect
    ~finally:(fun () -> get (Client.kill_pane client created.pane))
    (fun () ->
      let id = Pane.Target.id created.pane in
      let pane = capture_pane client id in
      let before =
        with_subscription client pane (fun subscription ->
            let cursor = echo client pane subscription "before-gap" in
            let extra =
              get
                (Client.split_pane client created.pane ~direction:Geometry.Right
                   ~spawn)
            in
            protect
              ~finally:(fun () -> get (Client.kill_pane client extra.pane))
              (fun () -> observe_gap ~clock subscription);
            cursor)
      in
      recover_coverage client id before)

let () =
  if Array.length Sys.argv <> 4 then (
    prerr_endline
      "usage: native_stream_recovery TMUX_BINARY SOCKET_PATH SESSION_ID";
    exit 2);
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let client =
    get
      (Client.connect ~sw ~binary:Sys.argv.(1)
         ~process_mgr:(Eio.Stdenv.process_mgr env)
         ~mono_clock:clock
         (Endpoint.socket_path Sys.argv.(2)))
  in
  protect
    ~finally:(fun () -> get (Client.close client))
    (fun () ->
      let id = get (Session.Id.of_string Sys.argv.(3)) in
      let session =
        match Snapshot.find_session (get (Client.capture client)) id with
        | Some session -> session
        | None -> failwith "requested session is absent"
      in
      recover ~clock client (Session.target session))
