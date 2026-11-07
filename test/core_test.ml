open Libtmux

let endpoints () =
  let invalid make value =
    match make value with
    | _ -> Alcotest.fail "invalid endpoint accepted"
    | exception Invalid_argument _ -> ()
  in
  List.iter (invalid Endpoint.named_socket) [ ""; "a/b"; "a\000b" ];
  List.iter (invalid Endpoint.socket_path) [ ""; "relative"; "/tmp/a\000b" ];
  let named = Endpoint.named_socket "work" in
  Alcotest.(check bool)
    "same description" true
    (Endpoint.equal named (Endpoint.named_socket "work"));
  Alcotest.(check bool)
    "distinct endpoint kinds" false
    (Endpoint.equal named (Endpoint.socket_path "/work"))

let cardinality () =
  let error = Alcotest.testable Cardinality.pp_error ( = ) in
  Alcotest.(check (result int error))
    "absence is explicit" (Error Cardinality.No_match)
    (Query.exactly_one Seq.empty);
  Alcotest.(check (result (option int) error))
    "optional absence" (Ok None)
    (Query.one_or_none Seq.empty);
  Alcotest.(check (result int error))
    "one value" (Ok 7)
    (Query.exactly_one (Seq.return 7));
  let inspected = ref 0 in
  let values =
    Seq.init 3 (fun _ ->
        incr inspected;
        if !inspected > 2 then Alcotest.fail "looked past the second match";
        7)
  in
  Alcotest.(check (result int error))
    "duplicates remain ambiguous"
    (Error (Cardinality.Multiple_matches { at_least = 2 }))
    (Query.exactly_one values);
  Alcotest.(check int) "short circuit" 2 !inspected;
  let exception Source_failure in
  let failing () = raise Source_failure in
  match Query.exactly_one (Seq.cons 7 failing) with
  | _ -> Alcotest.fail "source exception hidden"
  | exception Source_failure -> ()

let () =
  Alcotest.run "pure core"
    [
      ( "contracts",
        [
          Alcotest.test_case "explicit endpoints" `Quick endpoints;
          Alcotest.test_case "cardinality before effects" `Quick cardinality;
        ] );
    ]
