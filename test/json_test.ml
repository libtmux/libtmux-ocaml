open Libtmux
module Codec = Libtmux_json.Expr
module Decode_error = Libtmux_json.Decode_error

let get = function
  | Ok value -> value
  | Error error -> Alcotest.failf "%a" Decode_error.pp error

let document expression =
  `Assoc
    [
      ("schema", `String "libtmux.filter/1");
      ("model", `String "pane");
      ("expr", expression);
    ]

let compare field op value =
  `Assoc
    [
      ("node", `String "compare");
      ("field", `String field);
      ("op", `String op);
      ("value", value);
    ]

let round_trip () =
  let expression =
    Expr.all
      [
        Expr.Bool.is_true Pane.Fields.active;
        Expr.any
          [
            Expr.Text.is_in Pane.Fields.current_command [ "nvim"; "vim" ];
            Expr.Text.contains Pane.Fields.title "雪😀";
          ];
        Expr.Int.ge Pane.Fields.width 120;
      ]
  in
  let encoded = get (Codec.to_string Model.pane expression) in
  let decoded = get (Codec.of_string Model.pane encoded) in
  Iarray.iter
    (fun pane ->
      Alcotest.(check bool)
        "same evaluation"
        (Expr.compile expression pane)
        (Expr.compile decoded pane))
    (Snapshot.panes (Model_fixture.snapshot ()));
  let inequality =
    get
      (Codec.decode Model.pane
         (document (compare "pane_width" "not_equals" (`Int 120))))
  in
  Alcotest.(check bool)
    "inequality" false
    (Expr.compile inequality
       (Iarray.get (Snapshot.panes (Model_fixture.snapshot ())) 0))

let invalid_documents () =
  let reject name expected result =
    match result with
    | Error error when error.Decode_error.category = expected -> ()
    | Error error -> Alcotest.failf "%s: %a" name Decode_error.pp error
    | Ok _ -> Alcotest.fail (name ^ " was accepted")
  in
  let decode expression = Codec.decode Model.pane (document expression) in
  reject "wrong operand" Decode_error.Wrong_type
    (decode (compare "pane_width" "equals" (`String "120")));
  reject "overflow" Decode_error.Out_of_range
    (decode (compare "pane_width" "equals" (`Int 2_147_483_648)));
  reject "regex" Decode_error.Unsupported
    (decode
       (compare "pane_title" "matches" (`Assoc [ ("pattern", `String ".*") ])));
  reject "extension field" Decode_error.Unsupported
    (decode (compare "pane_dead" "equals" (`Bool false)));
  reject "extra property" Decode_error.Unknown
    (decode
       (`Assoc
          [
            ("node", `String "and");
            ("operands", `List []);
            ("extra", `Bool true);
          ]));
  reject "duplicates" Decode_error.Syntax
    (Codec.of_string Model.pane
       {|{"schema":"libtmux.filter/1","model":"pane","expr":{"node":"and","operands":[],"node":"or"}}|});
  reject "invalid utf8" Decode_error.Syntax
    (decode (compare "pane_title" "equals" (`String "\255")));
  reject "unpaired surrogate" Decode_error.Syntax
    (Codec.of_string Model.pane
       {|{"schema":"libtmux.filter/1","model":"pane","expr":{"node":"compare","field":"pane_title","op":"equals","value":"\ud800"}}|});
  reject "oversize document" Decode_error.Limit
    (Codec.of_string Model.pane (String.make 65_537 ' '));
  reject "depth before parse" Decode_error.Limit
    (Codec.of_string Model.pane (String.make 33 '['));
  reject "membership bound" Decode_error.Limit
    (decode
       (compare "pane_title" "in"
          (`List (List.init 257 (fun _ -> `String "x")))));
  reject "node bound" Decode_error.Limit
    (decode
       (`Assoc
          [
            ("node", `String "and");
            ( "operands",
              `List
                (List.init 1024 (fun _ ->
                     `Assoc [ ("node", `String "and"); ("operands", `List []) ]))
            );
          ]));
  reject "numeric membership differs in Java" Decode_error.Unsupported
    (Codec.encode Model.pane (Expr.Int.is_in Pane.Fields.width [ 120 ]));
  reject "encoding invalid bytes" Decode_error.Syntax
    (Codec.encode Model.pane (Expr.Text.equal Pane.Fields.title "\255"));
  reject "encoding byte bound" Decode_error.Limit
    (Codec.encode Model.pane
       (Expr.Text.equal Pane.Fields.title (String.make 65_500 'x')))

let plans () =
  let flag = Expr.Bool.is_true Pane.Fields.active in
  let hostile = Expr.Text.equal Pane.Fields.title "#{==:1,1},#}" in
  let plan expression = Model_fixture.get (Plan.panes expression) in
  Alcotest.(check bool)
    "complete supported expression" true
    (Option.is_some (Plan.source_filter (plan flag)));
  List.iter
    (fun expression ->
      Alcotest.(check bool)
        "no partial source filtering" true
        (Option.is_none (Plan.source_filter (plan expression)));
      match Plan.panes ~pushdown:Require_exact expression with
      | Error (Error.Unsupported _) -> ()
      | _ -> Alcotest.fail "unsupported exact plan accepted")
    [
      Expr.any [ flag; hostile ];
      Expr.not_ hostile;
      Expr.all [ flag; hostile ];
      Expr.Rel.is Pane.Relations.window
        (Expr.Rel.all Window.Relations.panes flag);
    ];
  let never = Model_fixture.get (Plan.panes ~pushdown:Never flag) in
  Alcotest.(check bool)
    "never policy" true
    (Option.is_none (Plan.source_filter never))

let () =
  Alcotest.run "query interchange"
    [
      ( "contracts",
        [
          Alcotest.test_case "typed round trip" `Quick round_trip;
          Alcotest.test_case "validation and bounds" `Quick invalid_documents;
          Alcotest.test_case "whole-expression pushdown" `Quick plans;
        ] );
    ]
