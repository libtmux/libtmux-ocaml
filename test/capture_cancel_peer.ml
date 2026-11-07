open Libtmux
module C = Libtmux_eio.Client
module O = Libtmux_eio.Operation

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

exception Cancel_waiter

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let client =
            get
              (C.connect ~sw
                 ~process_mgr:(Eio.Stdenv.process_mgr env)
                 ~mono_clock:(Eio.Stdenv.mono_clock env)
                 ~binary:Sys.argv.(1)
                 (Endpoint.socket_path Sys.argv.(2)))
          in
          let snapshot = get (C.capture client) in
          let pane =
            Option.get
              (Snapshot.find_pane snapshot (get (Pane.Id.of_string "%1")))
          in
          let op =
            get
              (C.submit client
                 (Operations.capture_text ~scratch_dir:Sys.argv.(3) pane
                    ~start:0 ~end_:2))
          in
          let context, context_ready = Eio.Promise.create () in
          let cancelled, cancellation_done = Eio.Promise.create () in
          Eio.Fiber.fork ~sw (fun () ->
              Eio.Cancel.sub (fun scope ->
                  Eio.Promise.resolve context_ready scope;
                  try
                    ignore (get (C.await op));
                    failwith "capture finished before test barrier"
                  with Eio.Cancel.Cancelled Cancel_waiter ->
                    Eio.Promise.resolve cancellation_done ()));
          let scope = Eio.Promise.await context in
          let input =
            Eio.Buf_read.of_flow ~max_size:1024 (Eio.Stdenv.stdin env)
          in
          assert (Eio.Buf_read.line input = "CANCEL");
          Eio.Cancel.cancel scope Cancel_waiter;
          Eio.Promise.await cancelled;
          print_endline "CANCELLED";
          (if Sys.argv.(4) = "close" then (
             let closing =
               Eio.Fiber.fork_promise ~sw (fun () -> get (C.close client))
             in
             let receipt =
               match get (O.inspect op) with
               | O.Outcome_unknown receipt -> receipt
               | _ -> failwith "closing lost the capture receipt"
             in
             assert (List.length receipt.owned_buffers = 1);
             print_endline "CLOSING";
             Eio.Promise.await_exn closing;
             List.iter
               (fun buffer -> print_endline ("BUFFER " ^ buffer))
               receipt.owned_buffers)
           else
             let text = get (C.await op) in
             assert (text.bytes = "%end 1 1 1\nhello\n\n");
             assert (
               match get (O.inspect op) with
               | O.Finished (Ok _) -> true
               | _ -> false);
             ignore (get (C.close client)));
          assert (Array.length (Sys.readdir Sys.argv.(3)) = 0);
          print_endline "DRAINED"))
