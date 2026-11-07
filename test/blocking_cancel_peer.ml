open Libtmux
module C = Libtmux_unix.Client
module O = Libtmux_unix.Operation
module K = Libtmux_unix.Cancellation

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let cancelled f =
  match f () with
  | _ -> failwith "cancelled waiter returned a result"
  | exception K.Cancelled -> ()

let interrupt op =
  K.with_ (fun token ->
      let canceller =
        Domain.spawn (fun () ->
            assert (read_line () = "CANCEL");
            K.cancel token;
            print_endline "REQUESTED")
      in
      Fun.protect
        ~finally:(fun () -> Domain.join canceller)
        (fun () -> cancelled (fun () -> C.await ~cancel:token op)));
  print_endline "CANCELLED"

let () =
  let client =
    get
      (C.connect ~timeout:0.25 ~binary:Sys.argv.(1)
         (Endpoint.socket_path Sys.argv.(2)))
  in
  Fun.protect
    ~finally:(fun () -> ignore (get (C.close client)))
    (fun () ->
      let before = Array.length (Sys.readdir "/proc/self/fd") in
      let queued = get (C.submit client (Operations.signal "must-not-send")) in
      K.with_ (fun token ->
          K.cancel token;
          cancelled (fun () -> C.await ~cancel:token queued));
      assert (get (O.inspect queued) = O.Not_started);
      let expired = K.with_ Fun.id in
      let escaped = get (C.submit client (Operations.signal "expired-token")) in
      cancelled (fun () -> C.await ~cancel:expired escaped);
      K.cancel expired;
      assert (get (O.inspect escaped) = O.Not_started);
      assert (Array.length (Sys.readdir "/proc/self/fd") = before);
      let snapshot = get (C.capture client) in
      let pane =
        Option.get (Snapshot.find_pane snapshot (get (Pane.Id.of_string "%1")))
      in
      (if Sys.argv.(4) = "deadline" then (
         let op =
           get (C.submit client (Operations.wait_for "never-signalled"))
         in
         interrupt op;
         assert (
           match get (O.inspect op) with
           | O.Outcome_unknown { cause = Error.Deadline_exceeded; _ } -> true
           | _ -> false);
         ignore (get (C.capture client)))
       else
         let op =
           get
             (C.submit client
                (Operations.capture_text ~scratch_dir:Sys.argv.(3) pane ~start:0
                   ~end_:2))
         in
         interrupt op;
         let text = get (C.await op) in
         assert (text.bytes = "%end 1 1 1\nhello\n\n");
         K.with_ (fun token ->
             K.cancel token;
             cancelled (fun () -> C.await ~cancel:token op));
         assert (
           match get (O.inspect op) with
           | O.Finished (Ok _) -> true
           | _ -> false));
      assert (Array.length (Sys.readdir "/proc/self/fd") = before);
      assert (Array.length (Sys.readdir Sys.argv.(3)) = 0);
      ignore (get (C.close client));
      print_endline "DRAINED")
