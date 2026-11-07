open Libtmux

type runner = {
  run : 'a. 'a Command.t -> ('a, Error.t) result;
  version : string;
}

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let payload =
  String.init 255 (fun i -> Char.chr (i + 1))
  ^ "\n%end 1 2 3\n\\001\\r\\n$NAME\\$NAME\\\\$NAME${NAME}$1$!`x`\";λ日本語"

let exercise runner =
  let run command = get (runner.run command) in
  let snapshot = run (Operations.capture ()) in
  let session = Session.target (Iarray.get (Snapshot.sessions snapshot) 0) in
  let window = Window.target (Iarray.get (Snapshot.windows snapshot) 0) in
  let pane = Pane.target (Iarray.get (Snapshot.panes snapshot) 0) in
  let scopes =
    Options.
      [
        Server;
        Global_sessions;
        Global_windows;
        Session session;
        Window window;
        Pane pane;
      ]
  in
  List.iter
    (fun scope ->
      let table =
        run (Operations.capture_options ~include_inherited:true scope)
      in
      assert (Source.equal table.source (Session.Target.source session));
      assert (Iarray.length table.entries > 0))
    scopes;
  let catalog = get (Options.catalog ~version:runner.version) in
  List.iter
    (fun (scope, kind) ->
      let table = run (Operations.capture_options scope) in
      Iarray.iter
        (fun descriptor ->
          if (not descriptor.Options.hook) && List.mem kind descriptor.scopes
          then assert (Option.is_some (Options.lookup table descriptor.name)))
        catalog)
    Options.
      [
        (Server, `Server); (Global_sessions, `Session); (Global_windows, `Window);
      ];
  let values =
    payload
    :: [
         "";
         "a\"b";
         "~";
         "~abc";
         "\"";
         "'";
         "$";
         "${";
         "$A";
         "\\$A";
         "\\\\$A";
         "a\"\nb";
         "\\n";
         "n\n";
         " #;${}%";
       ]
  in
  List.iteri
    (fun i value ->
      run
        (Operations.set_option (Pane pane)
           ~name:("@bytes" ^ Int.to_string i)
           (Text value)))
    values;
  let retained = run (Operations.capture_options (Pane pane)) in
  List.iteri
    (fun i value ->
      let entry =
        Option.get (Options.lookup retained ("@bytes" ^ Int.to_string i))
      in
      if entry.value <> Options.Scalar (Text value) then
        failwith ("option byte mismatch " ^ Int.to_string i))
    values;
  run (Operations.set_option Global_sessions ~name:"@inherit" (Text "global"));
  let read ?include_inherited name =
    run (Operations.read_option ?include_inherited (Session session) name)
  in
  assert (read "@inherit" = Some (Options.Scalar (Text "global")));
  assert (read ~include_inherited:false "@inherit" = None);
  run (Operations.set_option (Session session) ~name:"@inherit" (Text ""));
  assert (read "@inherit" = Some (Options.Scalar (Text "")));
  run (Operations.unset_option (Session session) "@inherit");
  assert (read "@inherit" = Some (Options.Scalar (Text "global")));
  assert (read "@missing" = None);
  let default = read "update-environment" in
  run (Operations.clear_option_array (Session session) "update-environment");
  assert (read "update-environment" = Some (Options.Array (Iarray.of_list [])));
  run
    (Operations.set_option ~index:17 (Session session)
       ~name:"update-environment" (Text "A B"));
  run
    (Operations.set_option ~append:true (Session session)
       ~name:"update-environment" (Text "C D"));
  assert (
    read "update-environment"
    = Some
        (Options.Array
           (Iarray.of_list
              Options.[ (0, Text "C"); (1, Text "D"); (17, Text "A B") ])));
  run (Operations.unset_option ~index:17 (Session session) "update-environment");
  assert (
    read "update-environment"
    = Some
        (Options.Array (Iarray.of_list Options.[ (0, Text "C"); (1, Text "D") ])));
  run (Operations.unset_option (Session session) "update-environment");
  assert (read "update-environment" = default);
  let inherited =
    run (Operations.capture_options ~include_inherited:true (Session session))
  in
  assert (Option.get (Options.lookup inherited "update-environment")).inherited;
  run
    (Operations.set_option (Session session) ~name:"repeat-time" (Integer 123L));
  assert (read "repeat-time" = Some (Options.Scalar (Integer 123L)));
  run (Operations.set_option (Session session) ~name:"mouse" (Bool true));
  assert (read "mouse" = Some (Options.Scalar (Bool true)));
  List.iter
    (fun command ->
      match runner.run command with
      | Error (Error.Invalid_input _) -> ()
      | _ -> failwith "invalid option accepted")
    [
      Operations.set_option Server ~name:"mouse" (Bool false);
      Operations.set_option (Session session) ~name:"repeat-time" (Text "123");
      Operations.set_option ~index:0 (Session session) ~name:"mouse" (Bool true);
      Operations.set_option (Session session) ~name:"@bytes" (Text "\000");
      Operations.set_option (Session session) ~name:"after-new-window"
        (Commands "kill-server");
    ];
  assert (read "repeat-time" = Some (Options.Scalar (Integer 123L)));
  assert (
    match
      runner.run
        (Operations.read_option (Session session) "not-a-built-in-option")
    with
    | Error (Error.Unsupported _) -> true
    | _ -> false);
  let missing =
    Session.Target.of_id
      ~source:(Session.Target.source session)
      (get (Session.Id.of_string "$4294967294"))
  in
  assert (
    match runner.run (Operations.read_option (Session missing) "@missing") with
    | Error (Error.Command_failed _) -> true
    | _ -> false);
  let set_variable name value =
    Hook.{ name = "set-environment"; arguments = [ "-g"; name; value ] }
  in
  let hook = "after-rename-window" in
  run
    (Operations.set_hook ~index:17 Global_sessions ~name:hook
       [ set_variable "LIBTMUX_HOOK_BYTES" payload ]);
  assert (
    run (Operations.read_hook ~include_inherited:false (Session session) hook)
    = None);
  let observed = run (Operations.capture_hooks Global_sessions) in
  let entry = Option.get (Options.lookup observed hook) in
  assert (
    match entry.value with
    | Options.Array entries ->
        Iarray.length entries = 1 && fst (Iarray.get entries 0) = 17
    | _ -> false);
  run (Operations.rename_window window ~name:"hooked");
  let environment = run (Operations.capture_environment Global) in
  assert (
    Environment.lookup environment "LIBTMUX_HOOK_BYTES" = Some (Value payload));
  run
    (Operations.set_hook ~append:true Global_sessions ~name:hook
       [ set_variable "LIBTMUX_HOOK_FIRST" "first" ]);
  assert (
    match run (Operations.read_hook (Session session) hook) with
    | Some (Options.Array entries) ->
        Iarray.to_list (Iarray.map fst entries) = [ 0; 17 ]
    | _ -> false);
  run (Operations.run_hook (Session session) hook);
  let environment = run (Operations.capture_environment Global) in
  assert (
    Environment.lookup environment "LIBTMUX_HOOK_FIRST" = Some (Value "first"));
  run (Operations.remove_hook ~index:0 Global_sessions hook);
  run (Operations.remove_hook Global_sessions hook);
  assert (
    run (Operations.read_hook Global_sessions hook)
    = Some (Options.Array (Iarray.of_list [])));
  run
    (Operations.set_hook (Pane pane) ~name:"pane-title-changed"
       [ set_variable "LIBTMUX_HOOK_PANE" "pane" ]);
  run (Operations.run_hook (Pane pane) "pane-title-changed");
  assert (
    Environment.lookup
      (run (Operations.capture_environment Global))
      "LIBTMUX_HOOK_PANE"
    = Some (Value "pane"));
  run (Operations.remove_hook (Pane pane) "pane-title-changed");
  run
    (Operations.set_hook (Session session) ~name:"@libtmux-custom"
       [ set_variable "LIBTMUX_HOOK_CUSTOM" payload ]);
  assert (
    match run (Operations.read_hook (Session session) "@libtmux-custom") with
    | Some (Options.Scalar (Text _)) -> true
    | _ -> false);
  run
    (Operations.set_option (Session session) ~name:"@broken-hook"
       (Text "no-such-tmux-command"));
  assert (
    match runner.run (Operations.run_hook (Session session) "@broken-hook") with
    | Error (Error.Unsupported _) -> true
    | _ -> false);
  run (Operations.remove_hook (Session session) "@broken-hook");
  run (Operations.remove_hook (Session session) "@libtmux-custom");
  assert (run (Operations.read_hook (Session session) "@libtmux-custom") = None);
  assert (
    match runner.run (Operations.run_hook Global_sessions hook) with
    | Error (Error.Invalid_input _) -> true
    | _ -> false);
  assert (
    match
      runner.run
        (Operations.set_hook (Session session) ~name:hook
           [ Hook.{ name = "set-environment; kill-server"; arguments = [] } ])
    with
    | Error (Error.Invalid_input _) -> true
    | _ -> false);
  run
    (Operations.set_hook (Session session) ~name:hook
       [
         set_variable "LIBTMUX_HOOK_BEFORE_FAILURE" "retained";
         Hook.{ name = "select-pane"; arguments = [ "-t"; "%4294967294" ] };
         set_variable "LIBTMUX_HOOK_AFTER_FAILURE" "must-not-run";
       ]);
  assert (
    match runner.run (Operations.run_hook (Session session) hook) with
    | Error (Error.Outcome_unknown _) -> true
    | _ -> false);
  assert (runner.run (Operations.capture ()) = Error Error.Closed);
  retained

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
              {
                run = (fun command -> Libtmux_unix.Client.run client command);
                version = Libtmux_unix.Client.version client;
              })
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
                      version = Libtmux_eio.Client.version client;
                    })))
  in
  assert (
    (Option.get (Options.lookup retained "@bytes0")).value
    = Scalar (Text payload));
  print_endline "PASS options, byte fidelity, scopes, arrays and inheritance"
