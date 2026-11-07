open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

type subscription = {
  next : unit -> Output.event option;
  poll : unit -> Output.event option;
  close : unit -> unit;
}

type runner = {
  run : 'a. 'a Command.t -> 'a;
  subscribe : int -> Pane.t -> subscription;
  close : unit -> unit;
  line : unit -> string;
}

let read_bytes sub expected =
  let result = Buffer.create 256 in
  let cursor = ref None in
  while Buffer.length result < String.length expected do
    match sub.next () with
    | Some (Output.Data { bytes; cursor = current }) ->
        Option.iter
          (fun before ->
            assert (Generation.equal before.Output.generation current.generation);
            assert (
              current.offset
              = Int64.add before.offset (Int64.of_int (String.length bytes))))
          !cursor;
        cursor := Some current;
        Buffer.add_string result bytes
    | Some (Gap { reason; _ } | End reason) ->
        failwith
          (Format.asprintf "unexpected stream end: %a" Output.reason_pp reason)
    | None -> failwith "stream ended before data"
  done;
  assert (Buffer.contents result = expected);
  Option.get !cursor

let gap sub reason =
  (match sub.next () with
  | Some (Output.Gap { reason = actual; _ }) when actual = reason -> ()
  | _ -> failwith "missing gap");
  assert (sub.next () = Some (Output.End reason));
  assert (sub.next () = None)

let exercise runner =
  let capture () = runner.run (Operations.capture ()) in
  let snapshot = capture () in
  let pane = Iarray.get (Snapshot.panes snapshot) 0 in
  let first = runner.subscribe 4096 pane in
  let slow = runner.subscribe 16 pane in
  let second = runner.subscribe 4096 pane in
  assert (Iarray.length (Snapshot.clients (capture ())) = 2);
  print_endline "READY";
  let expected = String.init 256 Char.chr ^ "DONE" in
  let before = read_bytes first expected in
  let other = read_bytes second expected in
  assert (not (Generation.equal before.generation other.generation));
  (match slow.next () with
  | Some (Output.Gap { reason = Overflow; lost_bytes = Some lost; _ }) ->
      assert (lost >= 256)
  | _ -> failwith "stalled subscriber did not report byte loss");
  assert (slow.next () = Some (Output.End Overflow));
  assert (first.poll () = None);
  second.close ();
  print_endline "CHANGE";
  gap first Output.Membership_changed;
  let fresh = Iarray.get (Snapshot.panes (capture ())) 0 in
  let recovered = runner.subscribe 4096 fresh in
  print_endline "RECOVER";
  let after = read_bytes recovered "recovered" in
  assert (not (Generation.equal before.generation after.generation));
  recovered.close ();
  assert (recovered.next () = Some (Output.End Cancelled));
  let subscriptions = List.init 16 (fun _ -> runner.subscribe 1024 fresh) in
  assert (Iarray.length (Snapshot.clients (capture ())) = 2);
  print_endline "CAPACITY";
  assert (runner.line () = "CHECKED");
  List.iter (fun (sub : subscription) -> sub.close ()) subscriptions;
  let final = runner.subscribe 1024 fresh in
  runner.close ();
  gap final Output.Client_closed;
  print_endline
    "PASS bytes, cursors, shared lanes, overflow, coverage and closure"

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  if Sys.argv.(3) = "unix" then
    let module C = Libtmux_unix.Client in
    let module S = Libtmux_unix.Subscription in
    let client = get (C.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (C.close client)))
      (fun () ->
        exercise
          {
            run = (fun command -> get (C.run client command));
            subscribe =
              (fun capacity_bytes pane ->
                let sub = get (C.subscribe ~capacity_bytes client pane) in
                {
                  next = (fun () -> get (S.next ~timeout:0.5 sub));
                  poll = (fun () -> get (S.poll sub));
                  close = (fun () -> get (S.close sub));
                });
            close = (fun () -> get (C.close client));
            line = read_line;
          })
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let module C = Libtmux_eio.Client in
            let module S = Libtmux_eio.Subscription in
            let client =
              get
                (C.connect ~sw ~binary
                   ~process_mgr:(Eio.Stdenv.process_mgr env)
                   ~mono_clock:(Eio.Stdenv.mono_clock env)
                   endpoint)
            in
            let input =
              Eio.Buf_read.of_flow ~max_size:1024 (Eio.Stdenv.stdin env)
            in
            Fun.protect
              ~finally:(fun () -> ignore (get (C.close client)))
              (fun () ->
                exercise
                  {
                    run = (fun command -> get (C.run client command));
                    subscribe =
                      (fun capacity_bytes pane ->
                        let sub =
                          get (C.subscribe ~capacity_bytes client pane)
                        in
                        {
                          next = (fun () -> get (S.next ~timeout:0.5 sub));
                          poll = (fun () -> get (S.poll sub));
                          close = (fun () -> get (S.close sub));
                        });
                    close = (fun () -> get (C.close client));
                    line = (fun () -> Eio.Buf_read.line input);
                  })))
