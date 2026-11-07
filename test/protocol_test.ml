module P = Libtmux__Protocol

let get = function
  | Ok value -> value
  | Error (P.Malformed s | P.Limit s) -> Alcotest.fail s

let reject = function
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "malformed input accepted"

let metadata () =
  let value = "a|=\\\n%end 1 2 3\t\255{}" in
  let quote escapes =
    let b = Buffer.create 64 in
    String.iter
      (fun c ->
        if String.contains escapes c then Buffer.add_char b '\\';
        Buffer.add_char b c)
      value;
    Buffer.contents b ^ "=\n"
  in
  List.iter
    (fun escapes ->
      let rows = get (P.Metadata.decode ~fields:1 (quote escapes)) in
      Alcotest.(check string)
        "lossless dialect" value
        (Iarray.get (Iarray.get rows 0) 0))
    [ "|&;<>()$`\\\"'*?[# =%"; P.Metadata.escaped ];
  List.iter
    (fun input -> reject (P.Metadata.decode ~fields:1 input))
    [ "bad\\x=\n"; "a|b=\n"; "a="; "a=\nx"; "a\\"; "%unquoted=\n"; "a\000=\n" ];
  reject (P.Metadata.decode ~max_field:3 ~fields:1 "1234=\n");
  reject (P.Metadata.decode ~max_rows:1 ~fields:1 "a=\nb=\n");
  let visual input =
    let rows = get (P.Metadata.decode ~dialect:Visual ~fields:1 input) in
    Iarray.get (Iarray.get rows 0) 0
  in
  Alcotest.(check string) "visual carriage return" "\r" (visual "\\r=\n");
  Alcotest.(check string)
    "literal escape remains literal" "\\r" (visual "\\\\r=\n");
  Alcotest.(check string)
    "visual dollar prefix" "$value" (visual "\\\\$value=\n");
  Alcotest.(check string) "visual opaque byte" "\255" (visual "\\377=\n");
  reject (P.Metadata.decode ~dialect:Visual ~fields:1 "\\400=\n");
  reject (P.Metadata.detect_print "unknown\n")

let framing () =
  let input =
    "%session-changed $1 fixture\n\
     %begin 10 20 1\n\
     a\\|b=\n\
     %end 10 20 1\n\
     %begin 10 21 1\n\
     error\n\
     %error 10 21 1\n\
     callback diagnostic\n"
  in
  let parse chunks =
    let state = P.Framer.create () in
    let events =
      List.concat_map (fun bytes -> get (P.Framer.feed state bytes)) chunks
    in
    get (P.Framer.finish state);
    events
  in
  let expected = parse [ input ] in
  for split = 0 to String.length input do
    Alcotest.(check bool)
      "every split boundary" true
      (expected
      = parse [ String.take_first split input; String.drop_first split input ])
  done;
  let state = P.Framer.create () in
  ignore (get (P.Framer.feed state "%begin 10 20 1\n"));
  reject (P.Framer.finish state);
  reject (P.Framer.feed state "%end 10 21 1\n");
  reject (P.Framer.feed state "%end 10 20 1\n");
  let limited = P.Framer.create ~max_frame:32 () in
  ignore (get (P.Framer.feed limited "%begin 1 1 1\n"));
  reject (P.Framer.feed limited (String.make 33 'x'));
  reject (P.Framer.feed (P.Framer.create ()) "%begin 1 1 1\n%begin 1 2 1\n")

let groups () =
  let state = P.Group.create ~count:3 ~marker:"owned-marker" in
  let frame ?(flags = 1) number ok body =
    P.Frame { guard = { time = 1L; number; flags }; ok; body }
  in
  Alcotest.(check bool)
    "acknowledgement is not completion" true
    (get (P.Group.accept state (frame 1L true "first\n")) = None);
  ignore (get (P.Group.accept state (P.Notification "%window-renamed @1 name")));
  ignore (get (P.Group.accept state (frame 2L false "missing pane\n")));
  ignore (get (P.Group.accept state (P.Diagnostic "late callback error")));
  assert (
    get (P.Group.accept state (frame ~flags:0 3L true "owned-marker\n")) = None);
  ignore (get (P.Group.accept state (frame ~flags:0 4L false "hook error\n")));
  let receipt =
    Option.get (get (P.Group.accept state (frame 3L true "owned-marker\n")))
  in
  Alcotest.(check bool)
    "failed group retains skipped tail" true
    (Iarray.to_list receipt.replies
    = [
        P.Group.Succeeded "first\n";
        P.Group.Failed "missing pane\n";
        P.Group.Skipped;
      ]);
  Alcotest.(check (list string))
    "callback diagnostic retained" [ "late callback error" ] receipt.diagnostics;
  Alcotest.(check int)
    "hook frames retained separately" 2
    (Iarray.length receipt.callbacks);
  reject (P.Group.accept state (frame 4L true "late\n"));
  reject
    (P.Group.accept
       (P.Group.create ~count:1 ~marker:"done")
       (frame 1L true "done\n"))

let boundaries () =
  Alcotest.(check string)
    "argv semicolon is data" "a\\\\;"
    (get (P.Command.argv_argument "a\\;"));
  let quoted = get (P.Command.quoted_argument "a'\n\r\t\\;") in
  Alcotest.(check bool)
    "one physical control line" false
    (String.contains quoted '\n');
  reject (P.Command.quoted_argument "a\000b");
  let opaque = get (P.Command.quoted_argument "\255\195\169\001\t") in
  Alcotest.(check bool)
    "opaque bytes use ASCII command syntax" true
    (String.for_all (fun c -> Char.code c >= 32 && Char.code c < 127) opaque);
  reject (P.Command.format_literal "#{pane_id}");
  reject (P.Command.render ~max_bytes:16 "display-message" [ "long" ]);
  reject (P.Command.quoted_argument ~max_bytes:8 "\255\255");
  Alcotest.(check string)
    "output bytes" "a\000\n\255\\"
    (get (P.Output.decode "a\\000\\012\\377\\134"));
  List.iter
    (fun text -> reject (P.Output.decode text))
    [ "\\"; "\\12"; "\\888"; "\\777" ];
  List.iter
    (fun version ->
      Alcotest.(check bool)
        "literal floor" true
        (P.Version.supported (get (P.Version.parse version))))
    [ "3.3"; "3.3a"; "tmux 3.4"; "3.8" ];
  Alcotest.(check bool)
    "older version rejected" false
    (P.Version.supported (get (P.Version.parse "3.2a")));
  reject (P.Version.parse "next-3.8")

let () =
  Alcotest.run "protocol codecs"
    [
      ( "contracts",
        [
          Alcotest.test_case "metadata dialects and limits" `Quick metadata;
          Alcotest.test_case "split frames and truncation" `Quick framing;
          Alcotest.test_case "group attribution and completion" `Quick groups;
          Alcotest.test_case "distinct command and output boundaries" `Quick
            boundaries;
        ] );
    ]
