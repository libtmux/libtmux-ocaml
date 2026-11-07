open Libtmux

let%expect_test "cardinality errors retain meaning" =
  let show = function
    | Ok value -> Printf.printf "selected %d\n" value
    | Error error -> Format.printf "%a@." Cardinality.pp_error error
  in
  show (Query.exactly_one Seq.empty);
  show (Query.exactly_one (List.to_seq [ 7; 7 ]));
  show (Query.exactly_one (Seq.return 7));
  [%expect {|
    no match
    at least 2 matches
    selected 7 |}]

let%expect_test "query explanation and transport errors" =
  let expression = Expr.Bool.is_true Pane.Fields.active in
  Format.printf "%a@." Expr.pp expression;
  List.iter
    (fun error -> Format.printf "%a@." Error.pp error)
    [
      Error.Stale_target;
      Error.Capacity { resource = "subscriptions"; limit = 16 };
    ];
  [%expect
    {|
    pane_active = true
    target belongs to another connection generation
    subscriptions capacity reached (16)
  |}]
