open Libtmux

type runner = { run : 'a. 'a Command.t -> ('a, Error.t) result }

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let payload =
  String.init 255 (fun i -> Char.chr (i + 1))
  ^ "\n%begin 1 2 3\n%end 1 2 3\n%error 1 2 3\n\\001\\r\\n"
  ^ "$NAME\\$NAME\\\\$NAME${NAME}$1$!`echo x`\"; export X;\nλ日本語"

let exercise runner =
  let run command = get (runner.run command) in
  let snapshot = run (Operations.capture ()) in
  let session = Session.target (Iarray.get (Snapshot.sessions snapshot) 0) in
  let local = Environment.Session session in
  let read ?hidden scope = run (Operations.capture_environment ?hidden scope) in
  let set ?hidden scope name value =
    run (Operations.set_environment ?hidden scope ~name value)
  in
  let check table name expected =
    if Environment.lookup table name <> expected then
      failwith ("environment value mismatch: " ^ name)
  in
  set Global "LIBTMUX_BYTES" payload;
  let captured = read Global in
  check captured "LIBTMUX_BYTES" (Some (Value payload));
  assert (Source.equal captured.source (Session.Target.source session));
  assert (captured.started_at_ns <= captured.finished_at_ns);
  set Global "LIBTMUX_SCOPE" "global";
  check (read local) "LIBTMUX_SCOPE" None;
  set local "LIBTMUX_SCOPE" "";
  check (read local) "LIBTMUX_SCOPE" (Some (Value ""));
  run (Operations.remove_environment local "LIBTMUX_SCOPE");
  check (read local) "LIBTMUX_SCOPE" (Some Removed);
  run (Operations.unset_environment local "LIBTMUX_SCOPE");
  check (read local) "LIBTMUX_SCOPE" None;
  check (read Global) "LIBTMUX_SCOPE" (Some (Value "global"));
  set ~hidden:true local "LIBTMUX_HIDDEN" payload;
  check (read local) "LIBTMUX_HIDDEN" None;
  let hidden = read ~hidden:true local in
  check hidden "LIBTMUX_HIDDEN" (Some (Value payload));
  assert hidden.hidden;
  check hidden "PATH" None;
  List.iter
    (fun name ->
      match runner.run (Operations.set_environment Global ~name "rejected") with
      | Error (Error.Invalid_input _) -> ()
      | _ -> failwith "invalid environment name accepted")
    [ ""; "-x"; "a=b"; "1name"; "a\n%end" ];
  assert (
    match
      runner.run
        (Operations.set_environment Global ~name:"LIBTMUX_BYTES" "\000")
    with
    | Error (Error.Invalid_input _) -> true
    | _ -> false);
  check (read Global) "LIBTMUX_BYTES" (Some (Value payload));
  run (Operations.unset_environment Global "LIBTMUX_BYTES");
  run (Operations.unset_environment Global "LIBTMUX_SCOPE");
  run (Operations.unset_environment local "LIBTMUX_HIDDEN");
  captured

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  let retained =
    if Sys.argv.(3) = "unix" then (
      let before = Array.length (Sys.readdir "/proc/self/fd") in
      let client = get (Libtmux_unix.Client.connect ~binary endpoint) in
      let captured =
        Fun.protect
          ~finally:(fun () -> ignore (get (Libtmux_unix.Client.close client)))
          (fun () ->
            exercise
              { run = (fun command -> Libtmux_unix.Client.run client command) })
      in
      assert (Array.length (Sys.readdir "/proc/self/fd") = before);
      captured)
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
              Fun.protect
                ~finally:(fun () ->
                  ignore (get (Libtmux_eio.Client.close client)))
                (fun () ->
                  exercise
                    {
                      run =
                        (fun command -> Libtmux_eio.Client.run client command);
                    })))
  in
  assert (Environment.lookup retained "LIBTMUX_BYTES" = Some (Value payload));
  print_endline "PASS environment bytes, scopes, hidden values and lifetime"
