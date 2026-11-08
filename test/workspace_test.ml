open Libtmux
open Libtmux_workspace

let config_error = Alcotest.testable Config.pp_error ( = )
let plan_error = Alcotest.testable Plan.pp_error ( = )

let get_config = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" Config.pp_error error

let get_plan = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" Plan.pp_error error

let unit_result value = Result.map (fun _ -> ()) value

let one ?(name = "new") ?(pane = Config.pane ()) () =
  Config.window ~name [ pane ]

let checked ?(session = "project") windows =
  get_config (Config.make ~directory:"/srv/config" ~session windows)

let paths_and_literals () =
  let command =
    Spawn.Exec
      { program = "printf"; args = [ "$HOME"; "a; b"; ""; "#{pane_id}" ] }
  in
  let pane =
    Config.pane
      ~spawn:(Spawn.make ~cwd:"pane" ~environment:[ ("A", "pane") ] command)
      ()
  in
  let window =
    Config.window ~name:"editor" ~cwd:"window"
      ~environment:[ ("A", "window"); ("B", "literal ${HOME}") ]
      [ pane ]
  in
  let config =
    get_config
      (Config.make ~directory:"/srv/config" ~cwd:"root"
         ~environment:[ ("A", "root"); ("C", "root") ]
         ~session:"project" [ window ])
  in
  let window = Iarray.get (Config.windows config) 0 in
  let pane = List.hd window.panes in
  Alcotest.(check (option string))
    "explicit window directory uses document" (Some "/srv/config/window")
    window.cwd;
  Alcotest.(check (option string))
    "explicit pane directory uses document" (Some "/srv/config/pane")
    pane.spawn.cwd;
  Alcotest.(check (list (pair string string)))
    "environment override order"
    [ ("C", "root"); ("B", "literal ${HOME}"); ("A", "pane") ]
    pane.spawn.environment;
  Alcotest.(check (list string))
    "argv remains literal"
    [ "$HOME"; "a; b"; ""; "#{pane_id}" ]
    (match pane.spawn.command with
    | Exec { args; _ } -> args
    | _ -> Alcotest.fail "lost argv");
  let shell = "printf '%s' \"${HOME};#{}\"" in
  let config =
    checked [ one ~pane:(Config.pane ~spawn:(Spawn.make (Shell shell)) ()) () ]
  in
  let pane = List.hd (Iarray.get (Config.windows config) 0).panes in
  Alcotest.(check string)
    "shell is explicitly requested literal code" shell
    (match pane.spawn.command with
    | Shell code -> code
    | _ -> Alcotest.fail "lost shell")

let reject_config () =
  let cases =
    [
      ( "/windows",
        "expected 1..64 windows",
        Config.make ~directory:"/srv" ~session:"work" [] );
      ( "/windows",
        "duplicate entry",
        Config.make ~directory:"/srv" ~session:"work" [ one (); one () ] );
      ( "/directory",
        "document directory must be absolute",
        Config.make ~directory:"relative" ~session:"work" [ one () ] );
      ( "/environment",
        "duplicate entry",
        Config.make ~directory:"/srv" ~session:"work"
          ~environment:[ ("A", "1"); ("A", "2") ]
          [ one () ] );
      ( "/windows/0/panes/0/exec",
        "NUL is unsupported",
        Config.make ~directory:"/srv" ~session:"work"
          [
            one
              ~pane:
                (Config.pane
                   ~spawn:
                     (Spawn.make
                        (Exec { program = "printf"; args = [ "\000" ] }))
                   ())
              ();
          ] );
      ( "/windows/0/panes/0",
        "startup commands must be single lines",
        Config.make ~directory:"/srv" ~session:"work"
          [ one ~pane:(Config.pane ~startup:[ "one\ntwo" ] ()) () ] );
      ( "/size",
        "dimensions must be 1..10000",
        Config.make ~directory:"/srv" ~session:"work" ~width:0 [ one () ] );
      ( "/variables",
        "directory variable cycle",
        Config.make ~directory:"/srv" ~session:"work"
          ~variables:[ ("A", "${B}"); ("B", "${A}") ]
          [ one () ] );
      ( "/cwd",
        "unknown directory variable",
        Config.make ~directory:"/srv" ~session:"work" ~cwd:"${UNKNOWN}"
          [ one () ] );
      ( "/cwd",
        "text exceeds 64 KiB",
        Config.make
          ~directory:("/" ^ String.make 65_000 'x')
          ~session:"work" ~cwd:(String.make 1024 'y')
          [ one () ] );
    ]
  in
  List.iter
    (fun (path, message, result) ->
      Alcotest.(check (result unit config_error))
        message
        (Error Config.{ path; message })
        (unit_result result))
    cases;
  let config =
    get_config
      (Config.make ~directory:"/srv/config" ~session:"work"
         ~variables:[ ("ROOT", "repo"); ("SRC", "${ROOT}/src") ]
         ~cwd:"${SRC}"
         [ one () ])
  in
  Alcotest.(check (option string))
    "explicit variables resolve without ambient environment"
    (Some "/srv/config/repo/src")
    (List.hd (Iarray.get (Config.windows config) 0).panes).spawn.cwd

let plan_shape () =
  let config =
    checked
      [
        one ~pane:(Config.pane ~startup:[ "echo 'literal; text'" ] ()) ();
        one ~name:"second" ();
      ]
  in
  let endpoint = Endpoint.named_socket "fixture" in
  let make ?server_policy ?collision_policy observed config =
    Plan.make ?server_policy ?collision_policy ~endpoint ~version:"3.3a"
      ~observed config
  in
  let plan = get_plan (make None config) in
  let labels =
    Plan.actions plan |> Iarray.to_list
    |> List.map (function
      | Plan.Create_session { bootstrap = true; _ } -> "bootstrap"
      | Create_session _ -> "session"
      | Create_window _ -> "window"
      | Send_text { text; _ } -> text
      | Send_enter _ -> "enter"
      | _ -> "unexpected")
  in
  Alcotest.(check (list string))
    "one initial pane; explicit text then Enter"
    [ "bootstrap"; "echo 'literal; text'"; "enter"; "window" ]
    labels;
  Alcotest.(check (result unit plan_error))
    "required missing endpoint" (Error Plan.Missing_endpoint)
    (unit_result (make ~server_policy:Require_existing_server None config));
  let observed = Model_fixture.snapshot () in
  let collision = checked ~session:"work" [ one () ] in
  Alcotest.(check (result unit plan_error))
    "default rejects session collision" (Error (Plan.Session_conflict "work"))
    (unit_result (make (Some observed) collision));
  let append = Plan.Append_new_windows { window_collision = Reject } in
  let existing_window = checked ~session:"work" [ one ~name:"api" () ] in
  Alcotest.(check (result unit plan_error))
    "append rejects existing window name" (Error (Plan.Window_conflict "api"))
    (unit_result
       (make ~collision_policy:append (Some observed) existing_window));
  let plan =
    get_plan (make ~collision_policy:append (Some observed) collision)
  in
  Alcotest.(check int)
    "append creates only requested new window" 1
    (Iarray.length (Plan.actions plan));
  Alcotest.(check (result unit plan_error))
    "same generation" (Ok ())
    (Plan.check_source plan (Some (Snapshot.source observed)));
  Alcotest.(check (result unit plan_error))
    "stale generation rejects before execution" (Error Plan.Stale)
    (Plan.check_source plan (Some (Model_fixture.source ~generation:'c' ())));
  Alcotest.(check (result unit plan_error))
    "endpoint mismatch rejects preview" (Error Plan.Stale)
    (unit_result
       (Plan.make
          ~endpoint:(Endpoint.named_socket "other")
          ~version:"3.3a" ~observed:(Some observed) collision))

let admission_bounds () =
  let environment = List.init 256 (fun i -> ("V" ^ Int.to_string i, "v")) in
  let pane =
    Config.pane
      ~spawn:(Spawn.make ~environment:[ ("EXTRA", "v") ] Spawn.Default)
      ()
  in
  let result =
    Config.make ~directory:"/srv" ~session:"work" ~environment [ one ~pane () ]
  in
  Alcotest.(check (result unit config_error))
    "merged environment is bounded before admission"
    (Error
       Config.
         {
           path = "/windows/0/panes/0/environment";
           message = "too many variables";
         })
    (unit_result result);
  let pane =
    Config.pane
      ~spawn:(Spawn.make (Exec { program = "-invalid"; args = [] }))
      ()
  in
  Alcotest.(check (result unit config_error))
    "executable cannot become a flag"
    (Error
       Config.
         {
           path = "/windows/0/panes/0/exec/0";
           message = "executable must not start with '-'";
         })
    (unit_result
       (Config.make ~directory:"/srv" ~session:"work" [ one ~pane () ]))

let plan_limit () =
  let startup = List.init 256 (fun _ -> "command") in
  let panes = List.init 16 (fun _ -> Config.pane ~startup ()) in
  let config = checked [ Config.window ~name:"bounded" panes ] in
  Alcotest.(check (result unit plan_error))
    "bound journal allocation before effects" (Error Plan.Too_many_steps)
    (unit_result
       (Plan.make
          ~endpoint:(Endpoint.named_socket "fixture")
          ~version:"3.3a" ~observed:None config))

let () =
  Alcotest.run "workspace"
    [
      ( "validation",
        [
          Alcotest.test_case "directories and literal commands" `Quick
            paths_and_literals;
          Alcotest.test_case "invalid values, bounds and expansion" `Quick
            reject_config;
          Alcotest.test_case "effective admission bounds" `Quick
            admission_bounds;
        ] );
      ( "planning",
        [
          Alcotest.test_case "bootstrap, collisions and generations" `Quick
            plan_shape;
          Alcotest.test_case "bounded plan" `Quick plan_limit;
        ] );
    ]
