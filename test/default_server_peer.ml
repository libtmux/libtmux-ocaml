open Libtmux

let checked pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let get result = checked Error.pp result

let local_version binary =
  let env =
    Unix.environment () |> Array.to_list
    |> List.filter (fun entry ->
        not
          (String.starts_with ~prefix:"TMUX=" entry
          || String.starts_with ~prefix:"TMUX_PANE=" entry))
    |> Array.of_list
  in
  let reader, writer = Unix.pipe ~cloexec:true () in
  let null = Unix.openfile "/dev/null" [ Unix.O_RDWR; Unix.O_CLOEXEC ] 0 in
  let pid =
    Fun.protect
      ~finally:(fun () ->
        Unix.close writer;
        Unix.close null)
      (fun () ->
        Unix.create_process_env binary [| binary; "-V" |] env null writer null)
  in
  let channel = Unix.in_channel_of_descr reader in
  let line =
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () -> String.trim (input_line channel))
  in
  assert (snd (Unix.waitpid [] pid) = Unix.WEXITED 0);
  String.sub line 5 (String.length line - 5)

let describe source =
  let kind, value =
    match Endpoint.kind (Source.endpoint source) with
    | Endpoint.Named_socket name -> ("named_socket", name)
    | Endpoint.Socket_path path -> ("socket_path", path)
  in
  Printf.sprintf "%d|%s|%s" (Source.server_pid source) kind value

let () =
  let mode = Sys.argv.(1)
  and binary = Sys.argv.(2)
  and backend = Sys.argv.(3) in
  let spawn = Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] }) in
  match (mode, backend) with
  | "connect", "unix" ->
      let module C = Libtmux_unix.Client in
      let client = get (C.connect ~binary (Endpoint.from_env ())) in
      let line = describe (C.source client) in
      get (C.close client);
      print_endline line
  | "connect", "eio" ->
      Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
              let module C = Libtmux_eio.Client in
              let client =
                get
                  (C.connect ~sw ~binary
                     ~process_mgr:(Eio.Stdenv.process_mgr env)
                     ~mono_clock:(Eio.Stdenv.mono_clock env)
                     (Endpoint.from_env ()))
              in
              let line = describe (C.source client) in
              get (C.close client);
              print_endline line))
  | "explicit", "unix" ->
      let module C = Libtmux_unix.Client in
      let endpoint =
        if Sys.argv.(4) = "path" then Endpoint.socket_path Sys.argv.(5)
        else Endpoint.named_socket Sys.argv.(5)
      in
      let client = get (C.connect ~binary endpoint) in
      Fun.protect
        ~finally:(fun () -> get (C.close client))
        (fun () -> print_endline (describe (C.source client)))
  | "explicit", "eio" ->
      let endpoint =
        if Sys.argv.(4) = "path" then Endpoint.socket_path Sys.argv.(5)
        else Endpoint.named_socket Sys.argv.(5)
      in
      Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
              let module C = Libtmux_eio.Client in
              let client =
                get
                  (C.connect ~sw ~binary
                     ~process_mgr:(Eio.Stdenv.process_mgr env)
                     ~mono_clock:(Eio.Stdenv.mono_clock env)
                     endpoint)
              in
              let line = describe (C.source client) in
              get (C.close client);
              print_endline line))
  | "nested", "unix" ->
      let name = Sys.argv.(4) in
      let module C = Libtmux_unix.Client in
      let client = get (C.connect ~binary (Endpoint.from_env ())) in
      Fun.protect
        ~finally:(fun () -> get (C.close client))
        (fun () ->
          let created = get (C.create_session client ~name ~spawn ()) in
          Printf.printf "%d|%s\n"
            (Source.server_pid (C.source client))
            (Session.Id.to_string (Session.Target.id created.session)))
  | "nested", "eio" ->
      let name = Sys.argv.(4) in
      Eio_main.run (fun env ->
          Eio.Switch.run (fun sw ->
              let module C = Libtmux_eio.Client in
              let client =
                get
                  (C.connect ~sw ~binary
                     ~process_mgr:(Eio.Stdenv.process_mgr env)
                     ~mono_clock:(Eio.Stdenv.mono_clock env)
                     (Endpoint.from_env ()))
              in
              Fun.protect
                ~finally:(fun () -> get (C.close client))
                (fun () ->
                  let created = get (C.create_session client ~name ~spawn ()) in
                  Printf.printf "%d|%s\n"
                    (Source.server_pid (C.source client))
                    (Session.Id.to_string (Session.Target.id created.session)))))
  | "bootstrap", _ ->
      let name = Sys.argv.(4) in
      let module Config = Libtmux_workspace.Config in
      let module Plan = Libtmux_workspace.Plan in
      let module Execution = Libtmux_workspace.Execution in
      let config =
        Config.make ~directory:(Sys.getcwd ()) ~session:name
          [ Config.window ~name:"main" [ Config.pane ~spawn () ] ]
        |> checked Config.pp_error
      in
      let endpoint = Endpoint.from_env () in
      let plan =
        Plan.make ~endpoint ~version:(local_version binary) ~observed:None
          config
        |> checked Plan.pp_error
      in
      if backend = "unix" then
        let module W = Libtmux_unix.Workspace in
        let handle =
          get (W.submit_bootstrap ~binary ~config_file:"/dev/null" plan)
        in
        Fun.protect
          ~finally:(fun () -> get (W.close handle))
          (fun () ->
            let receipt = get (W.await handle) in
            assert (receipt.status = Execution.Succeeded);
            let source = Option.get receipt.source in
            print_endline (describe source))
      else
        Eio_main.run (fun env ->
            Eio.Switch.run (fun sw ->
                let module W = Libtmux_eio.Workspace in
                let handle =
                  get
                    (W.submit_bootstrap ~binary ~config_file:"/dev/null" ~sw
                       ~process_mgr:(Eio.Stdenv.process_mgr env)
                       ~mono_clock:(Eio.Stdenv.mono_clock env)
                       plan)
                in
                Fun.protect
                  ~finally:(fun () -> get (W.close handle))
                  (fun () ->
                    let receipt = get (W.await handle) in
                    assert (receipt.status = Execution.Succeeded);
                    let source = Option.get receipt.source in
                    print_endline (describe source))))
  | _ -> failwith "unexpected mode or backend"
