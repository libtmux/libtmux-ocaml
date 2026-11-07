open Libtmux

type runner = {
  run : 'a. 'a Command.t -> ('a, Error.t) result;
  line : unit -> string;
}

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let with_client binary endpoint backend f =
  if backend = "unix" then
    let client = get (Libtmux_unix.Client.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (Libtmux_unix.Client.close client)))
      (fun () ->
        f
          {
            run = (fun command -> Libtmux_unix.Client.run client command);
            line = read_line;
          })
  else
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let client =
              get
                (Libtmux_eio.Client.connect ~sw ~binary
                   ~process_mgr:(Eio.Stdenv.process_mgr env)
                   ~mono_clock:(Eio.Stdenv.mono_clock env)
                   endpoint)
            in
            let input =
              Eio.Buf_read.of_flow ~max_size:1024 (Eio.Stdenv.stdin env)
            in
            Fun.protect
              ~finally:(fun () ->
                ignore (get (Libtmux_eio.Client.close client)))
              (fun () ->
                f
                  {
                    run = (fun command -> Libtmux_eio.Client.run client command);
                    line = (fun () -> Eio.Buf_read.line input);
                  })))

let () =
  let binary = Sys.argv.(1)
  and endpoint = Endpoint.socket_path Sys.argv.(2)
  and backend = Sys.argv.(3)
  and peer_pid = int_of_string Sys.argv.(4) in
  let observed snapshot =
    Snapshot.clients snapshot |> Iarray.to_seq
    |> Seq.filter (fun client -> Client_observation.pid client = peer_pid)
    |> Query.exactly_one |> Result.get_ok
  in
  let foreign =
    with_client binary endpoint backend (fun runner ->
        get (runner.run (Operations.capture ()))
        |> observed |> Client_observation.current_name)
  in
  with_client binary endpoint backend (fun runner ->
      let run command = get (runner.run command) in
      assert (
        match runner.run (Operations.refresh_client_at foreign) with
        | Error Error.Stale_target -> true
        | _ -> false);
      let snapshot = run (Operations.capture ()) in
      let original = observed snapshot in
      let name = Client_observation.current_name original in
      assert (Client_observation.control_mode original);
      let session =
        Snapshot.sessions snapshot |> Iarray.to_seq
        |> Seq.filter (fun session -> Session.name session = "destination")
        |> Query.exactly_one |> Result.get_ok
      in
      run (Operations.switch_client_at name ~session:(Session.target session));
      run (Operations.refresh_client_at name);
      run (Operations.refresh_client_at ~status_only:true name);
      run (Operations.resize_control_client_at name ~width:123 ~height:41);
      let switched = observed (run (Operations.capture ())) in
      assert (
        Session.Id.equal
          (Session.id (Option.get (Client_observation.session switched)))
          (Session.id session));
      assert (Client_observation.width switched = 123);
      assert (Client_observation.height switched = None);
      let version = Sys.argv.(5) in
      assert (
        get (Formats.lookup ~version (Client switched) "client_width")
        = Formats.Value (Int 123));
      assert (
        get (Formats.lookup ~version (Client switched) "client_height")
        = Formats.Missing);
      assert (
        get (Formats.lookup ~version (Client switched) "client_session")
        = Formats.Value (Text "destination"));
      assert (
        Session.name (Option.get (Client_observation.session original))
        = "fixture");
      run (Operations.request_detach_client_at name);
      print_endline "DETACH_REQUESTED";
      assert (runner.line () = "EXITED");
      assert (
        match runner.run (Operations.refresh_client_at name) with
        | Error (Error.Command_failed _) -> true
        | _ -> false);
      assert (
        not
          (Iarray.exists
             (fun client -> Client_observation.pid client = peer_pid)
             (Snapshot.clients (run (Operations.capture ())))));
      print_endline
        "PASS current client names, switch, refresh and detach request")
