open Libtmux

let endpoint_testable = Alcotest.testable Endpoint.pp Endpoint.equal

let endpoints () =
  let invalid make value =
    match make value with
    | _ -> Alcotest.fail "invalid endpoint accepted"
    | exception Invalid_argument _ -> ()
  in
  List.iter (invalid Endpoint.named_socket) [ ""; "."; ".."; "a/b"; "a\000b" ];
  List.iter (invalid Endpoint.socket_path) [ ""; "relative"; "/tmp/a\000b" ];
  let named = Endpoint.named_socket "work" in
  Alcotest.(check bool)
    "same description" true
    (Endpoint.equal named (Endpoint.named_socket "work"));
  Alcotest.(check bool)
    "distinct endpoint kinds" false
    (Endpoint.equal named (Endpoint.socket_path "/work"))

let endpoint_from_env () =
  let env pairs key = List.assoc_opt key pairs in
  let resolve ?(cwd = "/work/app") pairs =
    Endpoint.from_env ~getenv:(env pairs) ~cwd ()
  in
  let invalid ?(cwd = "/work/app") pairs =
    match Endpoint.from_env ~getenv:(env pairs) ~cwd () with
    | _ -> Alcotest.fail "invalid environment endpoint accepted"
    | exception Invalid_argument _ -> ()
  in
  Alcotest.(check endpoint_testable)
    "default socket when nothing is set"
    (Endpoint.named_socket "default")
    (resolve []);
  Alcotest.(check endpoint_testable)
    "absolute LIBTMUX_SOCKET_PATH"
    (Endpoint.socket_path "/srv/tmux.sock")
    (resolve [ ("LIBTMUX_SOCKET_PATH", "/srv/tmux.sock") ]);
  Alcotest.(check endpoint_testable)
    "relative LIBTMUX_SOCKET_PATH resolves against cwd"
    (Endpoint.socket_path "/work/app/run/tmux.sock")
    (resolve [ ("LIBTMUX_SOCKET_PATH", "run/tmux.sock") ]);
  Alcotest.(check endpoint_testable)
    "non-blank LIBTMUX_SOCKET_PATH stays untrimmed"
    (Endpoint.socket_path "/srv/ spaced ")
    (resolve [ ("LIBTMUX_SOCKET_PATH", "/srv/ spaced ") ]);
  Alcotest.(check endpoint_testable)
    "LIBTMUX_SOCKET_PATH beats LIBTMUX_SOCKET and TMUX without error"
    (Endpoint.socket_path "/srv/winner.sock")
    (resolve
       [
         ("LIBTMUX_SOCKET_PATH", "/srv/winner.sock");
         ("LIBTMUX_SOCKET", "invalid/slash");
         ("TMUX", "/srv/enclosing,123,0");
       ]);
  Alcotest.(check endpoint_testable)
    "LIBTMUX_SOCKET selects named socket"
    (Endpoint.named_socket "project")
    (resolve
       [ ("LIBTMUX_SOCKET", "project"); ("TMUX", "/srv/enclosing,123,0") ]);
  Alcotest.(check endpoint_testable)
    "non-blank LIBTMUX_SOCKET stays untrimmed"
    (Endpoint.named_socket " spaced ")
    (resolve [ ("LIBTMUX_SOCKET", " spaced ") ]);
  List.iter
    (fun blank ->
      Alcotest.(check endpoint_testable)
        "blank LIBTMUX_SOCKET_PATH leaves LIBTMUX_SOCKET in force"
        (Endpoint.named_socket "fallback")
        (resolve
           [ ("LIBTMUX_SOCKET_PATH", blank); ("LIBTMUX_SOCKET", "fallback") ]);
      Alcotest.(check endpoint_testable)
        "blank LIBTMUX_SOCKET_PATH and LIBTMUX_SOCKET fall through to TMUX"
        (Endpoint.socket_path "/tmp/enclosing")
        (resolve
           [
             ("LIBTMUX_SOCKET_PATH", blank);
             ("LIBTMUX_SOCKET", " \t\r\n ");
             ("TMUX", "/tmp/enclosing,4242,0");
           ]))
    [ ""; "   "; "\t\r\n\011\012" ];
  Alcotest.(check endpoint_testable)
    "TMUX splits at the first comma"
    (Endpoint.socket_path "/tmp/first")
    (resolve [ ("TMUX", "/tmp/first,second,4242,0") ]);
  Alcotest.(check endpoint_testable)
    "relative TMUX path resolves against cwd"
    (Endpoint.socket_path "/work/app/rel/enclosing")
    (resolve [ ("TMUX", "rel/enclosing,4242,0") ]);
  List.iter
    (fun ignored ->
      Alcotest.(check endpoint_testable)
        "empty or leading-comma TMUX uses default socket"
        (Endpoint.named_socket "default")
        (resolve [ ("TMUX", ignored) ]))
    [ ""; ",4242,0"; "   "; "   ,4242,0" ];
  List.iter (fun cwd -> invalid ~cwd []) [ ""; "relative"; "/bad\000cwd" ];
  invalid [ ("LIBTMUX_SOCKET_PATH", "/bad\000path") ];
  List.iter
    (fun bad -> invalid [ ("LIBTMUX_SOCKET", bad) ])
    [ "."; ".."; "bad/name"; "bad\000name" ];
  invalid [ ("TMUX", "/bad\000path,123,0") ]

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
          Alcotest.test_case "default server selection" `Quick endpoint_from_env;
          Alcotest.test_case "cardinality before effects" `Quick cardinality;
        ] );
    ]
