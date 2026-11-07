open Libtmux
open Model_fixture

let linked_graph () =
  let snapshot = snapshot () in
  let session = Iarray.get (Snapshot.sessions snapshot) 0 in
  let links = Session.window_links session in
  Alcotest.(check (list int))
    "repeated links retain indices" [ 2; 7 ]
    (Iarray.to_list (Iarray.map Window_link.index links));
  Alcotest.(check int)
    "global window deduplicated" 1
    (Iarray.length (Session.windows session));
  Alcotest.(check bool)
    "links have distinct context" false
    (Window_link.same_context (Iarray.get links 0) (Iarray.get links 1));
  let window = Iarray.get (Session.windows session) 0 in
  Alcotest.(check int)
    "all session links retained" 3
    (Iarray.length (Window.links window));
  let pane = Iarray.get (Window.panes window) 0 in
  Alcotest.(check bool)
    "back edge stays in observation" true
    (Window.same_observation window (Pane.window pane));
  let worker =
    Domain.spawn (fun () ->
        Iarray.map Pane.current_command (Snapshot.panes snapshot))
  in
  Alcotest.(check (list string))
    "domain sharing" [ "nvim"; "sh" ]
    (Iarray.to_list (Domain.join worker))

let identity () =
  let first = snapshot () in
  let newer = get (make ~id:'c' ()) in
  let replaced = get (make ~source:(source ~generation:'d' ()) ()) in
  let other_endpoint = get (make ~source:(source ~endpoint:"other" ()) ()) in
  let pane snap = Iarray.get (Snapshot.panes snap) 0 in
  Alcotest.(check bool)
    "new observation of same entity" true
    (Pane.same_entity (pane first) (pane newer));
  Alcotest.(check bool)
    "snapshot identity differs" false
    (Pane.same_observation (pane first) (pane newer));
  List.iter
    (fun snapshot ->
      Alcotest.(check bool)
        "server scope differs" false
        (Pane.same_entity (pane first) (pane snapshot)))
    [ replaced; other_endpoint ];
  let retained = pane first in
  Gc.full_major ();
  Alcotest.(check string)
    "view owns its captured graph" "api"
    (Window.name (Pane.window retained))

let invalid_graph () =
  let rejected name result =
    match result with
    | Error (Error.Capture_raced _) -> ()
    | _ -> Alcotest.fail name
  in
  let first = List.hd panes in
  let control_client =
    Snapshot.Input.
      {
        name = "control";
        session_id = None;
        pid = 42;
        width = 80;
        height = None;
        control_mode = true;
      }
  in
  let captured = get (make ~clients:[ control_client ] ()) in
  Alcotest.(check (option int))
    "control client has no terminal height" None
    (Client_observation.height (Iarray.get (Snapshot.clients captured) 0));
  rejected "zero client height accepted"
    (make ~clients:[ { control_client with height = Some 0 } ] ());
  let empty_pane =
    get (make ~panes:[ { first with pid = None; dead = true } ] ())
  in
  Alcotest.(check bool)
    "absent PID is represented explicitly" true
    (Pane.pid (Iarray.get (Snapshot.panes empty_pane) 0) = None);
  rejected "zero PID accepted as a process"
    (make ~panes:[ { first with pid = Some 0 } ] ());
  rejected "dangling window accepted"
    (make ~panes:[ { first with window_id = window_id "@9" } ] ());
  rejected "conflicting duplicates accepted"
    (make ~panes:(panes @ [ { first with title = "changed" } ]) ());
  rejected "missing panes accepted" (make ~panes:[] ());
  rejected "missing links accepted" (make ~window_links:[] ());
  rejected "duplicate pane index accepted"
    (make
       ~panes:
         (List.map
            (fun (p : Snapshot.Input.pane) -> { p with index = 0 })
            panes)
       ());
  rejected "multiple current links accepted"
    (make
       ~window_links:
         (List.map
            (fun (l : Snapshot.Input.window_link) ->
              { l with is_current = true })
            links)
       ());
  let with_duplicate = get (make ~windows:(windows @ windows) ()) in
  Alcotest.(check int)
    "identical global duplicates collapse" 1
    (Iarray.length (Snapshot.windows with_duplicate));
  let empty =
    get (make ~sessions:[] ~windows:[] ~window_links:[] ~panes:[] ())
  in
  Alcotest.(check int)
    "empty validated graph" 0
    (Iarray.length (Snapshot.panes empty));
  List.iter
    (fun id ->
      match Pane.Id.of_string id with
      | Error _ -> ()
      | Ok _ -> Alcotest.fail "noncanonical ID accepted")
    [ "%"; "%01"; "%4294967296"; "%1\000"; "@1" ]

let format_availability () =
  let first = List.hd panes in
  let captured =
    get (make ~panes:[ { first with pid = None; current_command = "" } ] ())
  in
  let pane = Iarray.get (Snapshot.panes captured) 0 in
  let read name = get (Formats.lookup ~version:"3.3" (Pane pane) name) in
  assert (read "pane_pid" = Formats.Missing);
  assert (read "pane_current_command" = Formats.Value (Text ""));
  assert (read "pane_width" = Formats.Value (Int 120));
  assert (read "session_id" = Formats.Unacquired);
  assert (read "pane_tty" = Formats.Unacquired);
  assert (read "does_not_exist" = Formats.Unsupported);
  assert (read "bracket_paste_flag" = Formats.Unsupported);
  assert (
    get (Formats.lookup ~version:"3.8" (Pane pane) "bracket_paste_flag")
    = Formats.Unacquired);
  assert (
    match Formats.catalog ~version:"unknown" with Error _ -> true | _ -> false);
  let links = Snapshot.window_links captured in
  List.iteri
    (fun i expected ->
      assert (
        get
          (Formats.lookup ~version:"3.3"
             (Window_link (Iarray.get links i))
             "window_index")
        = Formats.Value (Int expected)))
    [ 2; 7; 0 ];
  assert (
    get
      (Formats.lookup ~version:"3.3"
         (Window_link (Iarray.get links 2))
         "session_name")
    = Formats.Value (Text "also-work"))

let () =
  Alcotest.run "immutable graph"
    [
      ( "contracts",
        [
          Alcotest.test_case "linked graph and pure traversal" `Quick
            linked_graph;
          Alcotest.test_case "entity and observation identity" `Quick identity;
          Alcotest.test_case "complete graph validation" `Quick invalid_graph;
          Alcotest.test_case "versioned format availability" `Quick
            format_availability;
        ] );
    ]
