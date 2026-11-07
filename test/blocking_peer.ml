open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let interrupted_owner binary endpoint =
  let module Io = Libtmux_unix__Runtime_io in
  let module C = Libtmux_unix__Connection in
  let module E = Libtmux_unix__Engine in
  let interrupt = ref false in
  let io =
    { Io.blocking with check = (fun () -> if !interrupt then raise Exit) }
  in
  let connection = C.connect ~io ~binary endpoint in
  let client = E.create connection in
  Fun.protect
    ~finally:(fun () -> E.close client)
    (fun () ->
      let active = E.submit client (Operations.signal "interrupted-owner") in
      let queued =
        E.submit client (Operations.signal "queued-behind-interruption")
      in
      interrupt := true;
      (match E.await active with _ -> assert false | exception Exit -> ());
      assert connection.closed;
      assert (
        match E.inspect active with E.Outcome_unknown _ -> true | _ -> false);
      assert (E.inspect queued = E.Not_started))

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  match Client.connect ~binary endpoint with
  | Error (Error.Unsupported_version "3.2a") -> print_endline "REJECT 3.2a"
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)
  | Ok client ->
      let before = Array.length (Sys.readdir "/proc/self/fd") in
      let snapshot =
        Fun.protect
          ~finally:(fun () -> ignore (get (Client.close client)))
          (fun () ->
            interrupted_owner binary endpoint;
            let wrong_domain =
              Domain.spawn (fun () -> Client.capture client) |> Domain.join
            in
            assert (
              match wrong_domain with
              | Error Error.Wrong_domain -> true
              | _ -> false);
            let other = get (Client.connect ~binary endpoint) in
            assert (
              not (Source.equal (Client.source client) (Client.source other)));
            ignore (get (Client.close other));
            let snapshot = get (Client.capture client) in
            assert (Iarray.length (Snapshot.windows snapshot) = 1);
            assert (Iarray.length (Snapshot.window_links snapshot) = 2);
            assert (Iarray.length (Snapshot.panes snapshot) = 1);
            assert (
              Window.name (Iarray.get (Snapshot.windows snapshot) 0)
              = "hostile-%end-λ");
            let window = Iarray.get (Snapshot.windows snapshot) 0 in
            let operation =
              get
                (Client.submit client
                   (Operations.rename_window (Window.target window)
                      ~name:"literal-#{pid}"))
            in
            assert (
              match get (Libtmux_unix.Operation.inspect operation) with
              | Queued -> true
              | _ -> false);
            ignore (get (Client.await operation));
            assert (
              match get (Libtmux_unix.Operation.inspect operation) with
              | Finished (Ok ()) -> true
              | _ -> false);
            let updated = get (Client.capture client) in
            assert (
              Window.name (Iarray.get (Snapshot.windows updated) 0)
              = "literal-#{pid}");
            let cancelled =
              get
                (Client.submit client
                   (Operations.rename_window (Window.target window)
                      ~name:"wrong"))
            in
            ignore (get (Libtmux_unix.Operation.cancel cancelled));
            assert (
              match Client.await cancelled with
              | Error Error.Not_started -> true
              | _ -> false);
            let queued =
              List.init 64 (fun _ ->
                  get (Client.submit client (Operations.capture ())))
            in
            assert (
              match Client.submit client (Operations.capture ()) with
              | Error (Error.Capacity _) -> true
              | _ -> false);
            List.iter
              (fun op -> ignore (get (Libtmux_unix.Operation.cancel op)))
              queued;
            let pane = Iarray.get (Snapshot.panes snapshot) 0 in
            assert (
              match
                Client.submit client
                  (Operations.send_text (Pane.target pane) ~text:"bad\000text")
              with
              | Error (Error.Invalid_input _) -> true
              | _ -> false);
            let signal =
              get (Client.submit client (Operations.signal "ready"))
            in
            ignore (get (Client.run client (Operations.wait_for "ready")));
            ignore (get (Client.await signal));
            snapshot)
      in
      ignore (get (Client.close client));
      assert (Array.length (Sys.readdir "/proc/self/fd") < before);
      assert (
        Iarray.length
          (Session.windows (Iarray.get (Snapshot.sessions snapshot) 0))
        = 1);
      assert (
        match Client.capture client with
        | Error Error.Closed -> true
        | _ -> false);
      print_endline ("PASS " ^ Client.version client)
