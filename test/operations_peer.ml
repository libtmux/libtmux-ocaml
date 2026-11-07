open Libtmux

type runner = {
  run : 'a. 'a Command.t -> ('a, Error.t) result;
  failed_creation : Session.target -> Created.t list;
}

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let failed_creation ~submit ~await ~receipt session =
  let command =
    Operations.create_window ~index:4 ~name:"hook-failure"
      ~spawn:(Spawn.make (Exec { program = "/bin/cat"; args = [] }))
      session
  in
  let op = get (submit command) in
  assert (
    match await op with Error (Error.Outcome_unknown _) -> true | _ -> false);
  receipt op

let exercise runner program cwd =
  let run command = get (runner.run command) in
  let initial = run (Operations.capture ()) in
  let children = Hashtbl.create 16 in
  let snapshot () =
    let value = run (Operations.capture ()) in
    Iarray.iter
      (fun pane ->
        if Snapshot.find_pane initial (Pane.id pane) = None then
          Option.iter
            (fun pid ->
              if not (Hashtbl.mem children pid) then
                Hashtbl.add children pid (Libtmux_unix__Linux.pidfd_open pid))
            (Pane.pid pane))
      (Snapshot.panes value);
    value
  in
  let pane snapshot target =
    Option.get (Snapshot.find_pane snapshot (Pane.Target.id target))
  in
  let window snapshot target =
    Option.get (Snapshot.find_window snapshot (Window.Target.id target))
  in
  let original = Session.target (Iarray.get (Snapshot.sessions initial) 0) in
  let cat = Spawn.make (Exec { program = "/bin/cat"; args = [] }) in
  let spawn =
    Spawn.make ~cwd
      ~environment:[ ("LIBTMUX_TEST_VALUE", "literal-#{pid}\n%end 1 2 3") ]
      (Exec { program; args = [] })
  in
  assert (
    match
      runner.run (Operations.create_session ~width:0 ~name:"invalid" ())
    with
    | Error (Error.Invalid_input _) -> true
    | _ -> false);
  let created =
    run
      (Operations.create_session ~name:"created-#{pid}"
         ~window_name:"main-#{pid}" ~width:120 ~height:40 ~spawn ())
  in
  run (Operations.wait_for "program-ready");
  let captured = snapshot () in
  let session =
    Option.get
      (Snapshot.find_session captured (Session.Target.id created.session))
  in
  assert (Session.name session = "created-#{pid}");
  assert (Window.name (window captured created.window) = "main-#{pid}");
  assert (Pane.current_path (pane captured created.pane) = cwd);
  let extra =
    run
      (Operations.create_window ~index:3 ~name:"extra" ~spawn:cat
         created.session)
  in
  assert (extra.window_index = 3);
  assert (
    match
      runner.run (Operations.create_window ~index:3 ~spawn:cat created.session)
    with
    | Error (Error.Command_failed _) -> true
    | _ -> false);
  run (Operations.link_window created.window ~session:original ~index:8);
  run (Operations.link_window created.window ~session:created.session ~index:9);
  assert (Iarray.length (Window.links (window (snapshot ()) created.window)) = 3);
  run
    (Operations.move_window_at created.session ~from_index:9 ~session:original
       ~index:10);
  run (Operations.select_window_at original ~index:10);
  run (Operations.unlink_window_at original ~index:8);
  run (Operations.unlink_window_at original ~index:10);
  assert (Iarray.length (Window.links (window (snapshot ()) created.window)) = 1);
  assert (
    match
      runner.run
        (Operations.unlink_window_at created.session ~index:created.window_index)
    with
    | Error (Error.Command_failed _) -> true
    | _ -> false);
  run (Operations.select_window_at created.session ~index:3);
  let split =
    run
      (Operations.split_pane ~size:(Geometry.Percent 40) ~spawn:cat extra.pane
         ~direction:Right)
  in
  run (Operations.select_pane split.pane);
  run (Operations.set_pane_title split.pane ~title:"title-#{pid}");
  run (Operations.resize_window ~width:120 ~height:40 extra.window);
  run (Operations.resize_pane ~width:30 split.pane);
  let captured = snapshot () in
  assert (Pane.active (pane captured split.pane));
  assert (Pane.title (pane captured split.pane) = "title-#{pid}");
  assert (Pane.width (pane captured split.pane) = 30);
  List.iter
    (fun layout ->
      run (Operations.select_layout extra.window layout);
      let observed = snapshot () in
      let first = pane observed extra.pane
      and second = pane observed split.pane in
      assert (
        Pane.left first + Pane.width first <= Pane.left second
        || Pane.left second + Pane.width second <= Pane.left first
        || Pane.top first + Pane.height first <= Pane.top second
        || Pane.top second + Pane.height second <= Pane.top first))
    [
      Layout.Tiled;
      Main_horizontal;
      Main_vertical;
      Even_vertical;
      Even_horizontal;
    ];
  let arranged = snapshot () in
  let first = pane arranged extra.pane and second = pane arranged split.pane in
  assert (Pane.left first = 0 && Pane.top first = 0);
  assert (Pane.left second = Pane.width first + 1 && Pane.top second = 0);
  assert (Pane.width first + Pane.width second + 1 = 120);
  assert (Pane.height first = 40 && Pane.height second = 40);
  let layout = Window.layout (window arranged extra.window) in
  run (Operations.cycle_layout extra.window `Next);
  run (Operations.select_layout extra.window (Custom layout));
  assert (Window.layout (window (snapshot ()) extra.window) = layout);
  run (Operations.zoom_pane split.pane);
  let zoomed = pane (snapshot ()) split.pane in
  assert (Pane.width zoomed = 120 && Pane.height zoomed = 40);
  run (Operations.zoom_pane split.pane);
  run (Operations.swap_panes split.pane extra.pane);
  run (Operations.rotate_panes extra.window `Forward);
  run
    (Operations.move_pane ~size:(Geometry.Cells 6) split.pane
       ~beside:created.pane ~direction:Below);
  assert (
    Window.Id.equal
      (Window.id (Pane.window (pane (snapshot ()) split.pane)))
      (Window.Target.id created.window));
  let broken =
    run
      (Operations.break_pane ~name:"broken" split.pane ~session:created.session
         ~index:5)
  in
  assert (Pane.Id.equal (Pane.Target.id broken.pane) (Pane.Target.id split.pane));
  assert (broken.window_index = 5);
  run (Operations.clear_history created.pane);
  assert (
    match runner.run (Operations.respawn_pane extra.pane cat) with
    | Error (Error.Command_failed _) -> true
    | _ -> false);
  run (Operations.respawn_pane ~kill_running:true extra.pane cat);
  ignore (snapshot ());
  run (Operations.kill_pane broken.pane);
  assert (
    Snapshot.find_window (snapshot ()) (Window.Target.id broken.window) = None);
  run (Operations.kill_window extra.window);
  run (Operations.kill_session created.session);
  let final = snapshot () in
  assert (Iarray.length (Snapshot.sessions final) = 1);
  assert (Iarray.length (Snapshot.windows final) = 1);
  assert (Iarray.length (Snapshot.panes final) = 1);
  assert (Iarray.length (Snapshot.panes captured) = 4);
  let deadline = Libtmux_unix__Linux.now () +. 0.5 in
  let rec exited () =
    let pending =
      Hashtbl.to_seq_values children
      |> Seq.filter Libtmux_unix__Linux.pidfd_alive
      |> List.of_seq
    in
    if pending <> [] then (
      let remaining = deadline -. Libtmux_unix__Linux.now () in
      assert (remaining > 0.);
      ignore (Unix.select pending [] [] remaining);
      exited ())
  in
  exited ();
  Hashtbl.iter (fun _ fd -> Unix.close fd) children;
  print_endline "PASS creation, links, geometry, movement and teardown"

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  let program = Sys.argv.(4) and cwd = Sys.argv.(5) in
  let exercise runner program cwd =
    if Sys.getenv_opt "LIBTMUX_TEST_FAILURE" = Some "hook" then
      let snapshot = get (runner.run (Operations.capture ())) in
      let target = Session.target (Iarray.get (Snapshot.sessions snapshot) 0) in
      match runner.failed_creation target with
      | [ created ] ->
          print_endline
            ("CREATED " ^ Window.Id.to_string (Window.Target.id created.window));
          assert (created.window_index = 4);
          print_endline "PASS retained creation after hook failure"
      | _ -> failwith "creation receipt lost after hook failure"
    else exercise runner program cwd
  in
  if Sys.argv.(3) = "unix" then
    let client = get (Libtmux_unix.Client.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (Libtmux_unix.Client.close client)))
      (fun () ->
        exercise
          {
            run = (fun command -> Libtmux_unix.Client.run client command);
            failed_creation =
              failed_creation ~submit:(Libtmux_unix.Client.submit client)
                ~await:Libtmux_unix.Client.await ~receipt:(fun op ->
                  match get (Libtmux_unix.Operation.inspect op) with
                  | Outcome_unknown receipt -> receipt.created
                  | _ -> failwith "missing uncertain operation");
          }
          program cwd)
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
                    run = (fun command -> Libtmux_eio.Client.run client command);
                    failed_creation =
                      failed_creation ~submit:(Libtmux_eio.Client.submit client)
                        ~await:Libtmux_eio.Client.await ~receipt:(fun op ->
                          match get (Libtmux_eio.Operation.inspect op) with
                          | Outcome_unknown receipt -> receipt.created
                          | _ -> failwith "missing uncertain operation");
                  }
                  program cwd)))
