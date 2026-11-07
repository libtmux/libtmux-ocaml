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

let () =
  Alcotest.run "workspace JSON"
    [
      ( "schema",
        [
          Alcotest.test_case "literal commands, paths and settings" `Quick valid;
          Alcotest.test_case "strict input and limits" `Quick rejected;
        ] );
    ]
