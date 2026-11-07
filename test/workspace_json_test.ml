open Libtmux
module W = Libtmux_json.Workspace
module C = Libtmux_workspace.Config
module E = Libtmux_json.Decode_error

let get = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" E.pp error

let document pane =
  {|{"schema":"libtmux.workspace/1","session":"project","windows":[{"name":"editor","panes":[|}
  ^ pane ^ {|]}]}|}

let valid () =
  let source =
    {|{"schema":"libtmux.workspace/1","session":"project","cwd":"src",
    "variables":{"ROOT":"checkout"},"environment":{"ROOT":"literal"},
    "options":[{"name":"@purpose","kind":"text","value":"dev"}],
    "windows":[{"name":"editor","layout":"tiled","panes":[
      {"exec":["printf","%s","a; b",""],"cwd":"${ROOT}","direction":"right","size":{"percent":40}},
      {"shell":"exec cat","startup":["literal command"],"options":[{"name":"@pane","kind":"text","value":"v"}]}]}]}|}
  in
  let config = get (W.of_string ~directory:"/srv/project" source) in
  Alcotest.(check string) "session" "project" (C.session config);
  let window = Iarray.get (C.windows config) 0 in
  Alcotest.(check (option string))
    "inherited root cwd" (Some "/srv/project/src") window.cwd;
  let pane = List.hd window.panes in
  Alcotest.(check (option string))
    "explicit variable cwd" (Some "/srv/project/checkout") pane.spawn.cwd;
  Alcotest.(check (list string))
    "argv punctuation and empty argument" [ "%s"; "a; b"; "" ]
    (match pane.spawn.command with
    | Exec { args; _ } -> args
    | _ -> Alcotest.fail "expected argv");
  Alcotest.(check (option int))
    "split percentage" (Some 40)
    (match pane.size with Some (Geometry.Percent n) -> Some n | _ -> None)

let rejected () =
  let error = Alcotest.testable E.pp ( = ) in
  let check source pointer category =
    match W.of_string ~directory:"/srv/project" source with
    | Ok _ -> Alcotest.fail "invalid document decoded"
    | Error actual ->
        Alcotest.(check error)
          "pointer and category"
          E.{ pointer; category; message = actual.message }
          actual
  in
  check
    (document {|{"exec":["cat"],"shell":"cat"}|})
    "/windows/0/panes/0" E.Wrong_type;
  check (document {|{"exec":[]}|}) "/windows/0/panes/0/exec" E.Wrong_type;
  check
    (document {|{"exec":["cat",7]}|})
    "/windows/0/panes/0/exec/1" E.Wrong_type;
  check
    (document {|{"shell":"one","shell":"two"}|})
    "/windows/0/panes/0/shell" E.Syntax;
  check (document {|{"ignored":true}|}) "/windows/0/panes/0/ignored" E.Unknown;
  check
    (document {|{"size":{"cells":1,"percent":10}}|})
    "/windows/0/panes/0/size" E.Wrong_type;
  check
    (document {|{"size":{"percent":100}}|})
    "/windows/0/panes/0/size" E.Wrong_type;
  check
    (document {|{"cwd":"${UNKNOWN}"}|})
    "/windows/0/panes/0/cwd" E.Wrong_type;
  check
    (document {|{"exec":["printf","\u0000"]}|})
    "/windows/0/panes/0/exec" E.Wrong_type;
  check
    (document {|{"environment":{"A":"one","A":"two"}}|})
    "/windows/0/panes/0/environment/A" E.Syntax;
  check {|{"schema":"libtmux.workspace/2","session":"x","windows":[]}|}
    "/schema" E.Unsupported;
  check (String.make 65_537 ' ') "" E.Limit;
  check (document ("{\"shell\":\"" ^ String.make 1 '\255' ^ "\"}")) "" E.Syntax;
  check
    (document
       {|{"options":[{"name":"@x","kind":"number","value":9223372036854775808}]}|})
    "/windows/0/panes/0/options/0/value" E.Out_of_range

let output_contract () =
  let module P = Libtmux_workspace.Plan in
  let module X = Libtmux_workspace.Execution in
  let open Yojson.Safe.Util in
  let config =
    get
      (W.of_string ~directory:"/srv/project"
         (document {|{"exec":["cat"],"environment":{"TOKEN":"private"}}|}))
  in
  let endpoint = Endpoint.socket_path "/tmp/libtmux-ocaml-wire" in
  let plan =
    Result.get_ok (P.make ~endpoint ~version:"3.3" ~observed:None config)
  in
  let preview = get (W.encode_plan plan) in
  Alcotest.(check string)
    "preview schema" "libtmux.workspace-plan/1"
    (preview |> member "schema" |> to_string);
  Alcotest.(check bool) "advisory" true (preview |> member "advisory" |> to_bool);
  let spawn =
    preview |> member "actions" |> to_list |> List.hd |> member "action"
    |> member "spawn"
  in
  Alcotest.(check (list string))
    "environment names only" [ "TOKEN" ]
    (spawn |> member "environment_names" |> to_list |> List.map to_string);
  Alcotest.(check bool)
    "preview cannot execute as config" true
    (Result.is_error (W.decode ~directory:"/srv/project" preview));
  let source =
    Result.get_ok
      (Source.create ~endpoint ~server_pid:1
         ~generation:(Result.get_ok (Generation.of_string (String.make 64 '0'))))
  in
  let pane =
    Pane.Target.of_id ~source (Result.get_ok (Pane.Id.of_string "%7"))
  in
  let created =
    Created.
      {
        session =
          Session.Target.of_id ~source
            (Result.get_ok (Session.Id.of_string "$2"));
        window =
          Window.Target.of_id ~source (Result.get_ok (Window.Id.of_string "@4"));
        pane;
        window_index = 3;
        pane_index = 1;
      }
  in
  let action = Iarray.get (P.actions plan) 0 in
  let step index status created =
    X.{ index; action; status; created; unbound = None }
  in
  let receipt =
    X.
      {
        operation_id = "wire-test";
        source = Some source;
        status = Partial;
        steps =
          Iarray.of_list
            [
              step 0 Completed [ created ];
              step 1
                (Failed
                   (Error.Command_failed
                      {
                        command = "split-window";
                        message = "\255" ^ String.make 5000 'x';
                      }))
                [];
              step 2 Skipped [];
              step 3 (Uncertain (Error.Outcome_unknown "interrupted")) [];
            ];
        cleanup =
          Iarray.of_list [ { pane; outcome = Error Error.Deadline_exceeded } ];
        cleanup_error = None;
      }
  in
  let encoded = get (W.encode_receipt receipt) in
  Alcotest.(check string)
    "receipt schema" "libtmux.workspace-receipt/1"
    (encoded |> member "schema" |> to_string);
  List.iter
    (fun (name, expected) ->
      Alcotest.(check (list int))
        name expected
        (encoded |> member name |> to_list |> List.map to_int))
    [
      ("completed", [ 0 ]);
      ("failed", [ 1 ]);
      ("skipped", [ 2 ]);
      ("uncertain", [ 3 ]);
      ("pending", []);
    ];
  let error =
    encoded |> member "steps" |> to_list |> fun steps ->
    List.nth steps 1 |> member "error"
  in
  Alcotest.(check bool)
    "diagnostic truncation" true
    (error |> member "message_truncated" |> to_bool);
  Alcotest.(check string)
    "byte encoding" "hex"
    (error |> member "message" |> member "encoding" |> to_string);
  Alcotest.(check int)
    "bounded bytes" 8192
    (error |> member "message" |> member "bytes" |> to_string |> String.length);
  Alcotest.(check string)
    "created pane" "%7"
    (encoded |> member "cleanup" |> to_list |> List.hd |> member "pane"
   |> to_string);
  let unbound =
    X.
      {
        session = Session.Target.id created.session;
        window = Window.Target.id created.window;
        pane = Pane.Target.id pane;
        window_index = 3;
        pane_index = 1;
        server_pid = 1;
      }
  in
  let reported =
    {
      receipt with
      source = None;
      steps =
        Iarray.of_list
          [
            X.
              {
                index = 0;
                action;
                status = Uncertain (Error.Outcome_unknown "binding interrupted");
                created = [];
                unbound = Some unbound;
              };
          ];
    }
    |> W.encode_receipt |> get
  in
  Alcotest.(check bool)
    "unbound source absent" true
    (reported |> member "source" = `Null);
  Alcotest.(check string)
    "unbound hint retained" "%7"
    (reported |> member "steps" |> to_list |> List.hd |> member "unbound"
   |> member "pane" |> to_string);
  let excessive =
    { receipt with steps = Iarray.init 10_000 (fun i -> step i Pending []) }
  in
  Alcotest.(check bool)
    "bounded output" true
    (match W.encode_receipt excessive with
    | Error { category = Limit; _ } -> true
    | _ -> false)

let () =
  Alcotest.run "workspace JSON"
    [
      ( "schema",
        [
          Alcotest.test_case "literal commands, paths and settings" `Quick valid;
          Alcotest.test_case "strict input and limits" `Quick rejected;
          Alcotest.test_case "advisory plans and bounded journals" `Quick
            output_contract;
        ] );
    ]
