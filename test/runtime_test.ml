open Libtmux
module File = Libtmux_unix__Capture_file
module Io = Libtmux_unix__Runtime_io
module Budget = Libtmux_unix__Connection.Budget

let failure f =
  match Io.protect f with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "fault accepted"

let capture_identity () =
  let file = File.create "/tmp" in
  Fun.protect
    ~finally:(fun () -> File.cleanup file)
    (fun () ->
      assert ((Unix.stat file.directory).st_perm = 0o700);
      assert ((Unix.fstat file.fd).st_perm = 0o600);
      (match Io.protect (fun () -> File.create file.path) with
      | Error (Error.Disconnected _) ->
          Alcotest.fail "scratch failure reported as disconnect"
      | Error (Error.Filesystem _) -> ()
      | Error _ -> Alcotest.fail "wrong scratch error kind"
      | Ok _ -> Alcotest.fail "created directory below a regular file");
      ignore (Unix.write_substring file.fd "abc" 0 3);
      Alcotest.(check string) "exact file" "abc" (File.read file ~expected:3);
      failure (fun () -> File.read file ~expected:2);
      failure (fun () -> File.read file ~expected:4);
      failure (fun () -> File.read file ~expected:(File.max_bytes + 1));
      let original = file.path ^ "-original" in
      Unix.rename file.path original;
      Fun.protect
        ~finally:(fun () ->
          Unix.unlink file.path;
          Unix.rename original file.path)
        (fun () ->
          let replacement =
            Unix.openfile file.path
              [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY ]
              0o600
          in
          Unix.close replacement;
          failure (fun () -> File.read file ~expected:0)))

let payload_budget () =
  let budget = Budget.create () in
  Budget.reserve budget (24 * 1024 * 1024);
  failure (fun () -> Budget.reserve budget (9 * 1024 * 1024));
  Alcotest.(check int)
    "failed reservation has no charge"
    (24 * 1024 * 1024)
    budget.used;
  (try Budget.during budget 65_536 (fun () -> raise Exit) with Exit -> ());
  Alcotest.(check int)
    "exception releases reservation"
    (24 * 1024 * 1024)
    budget.used;
  Budget.release budget (24 * 1024 * 1024);
  Alcotest.(check int) "all released" 0 budget.used

let ready_deadline () =
  let reader, writer = Unix.pipe ~cloexec:true () in
  Fun.protect
    ~finally:(fun () ->
      Unix.close reader;
      Unix.close writer)
    (fun () ->
      Unix.set_nonblock reader;
      Unix.set_nonblock writer;
      ignore (Unix.write_substring writer "available" 0 9);
      let process =
        Io.
          {
            input = writer;
            output = reader;
            error = reader;
            stop = (fun () -> ());
          }
      in
      let deadline = Libtmux_unix__Linux.now () -. 1. in
      let expired f =
        match Io.protect f with
        | Error Error.Deadline_exceeded -> ()
        | _ -> Alcotest.fail "ready I/O bypassed the deadline"
      in
      expired (fun () -> Io.read Io.blocking process ~pidfd:None ~deadline);
      expired (fun () ->
          Io.write Io.blocking process ~pidfd:None ~deadline "late"))

let cancellation_lifetime () =
  let module K = Libtmux_unix__Cancellation in
  let before = Array.length (Sys.readdir "/proc/self/fd") in
  let mutex = Mutex.create () and ready = Condition.create () in
  let borrowed = ref false in
  let worker =
    K.with_ (fun token ->
        let worker =
          Domain.spawn (fun () ->
              K.borrow token (fun fd ->
                  Mutex.protect mutex (fun () ->
                      borrowed := true;
                      Condition.signal ready);
                  let readable, _, _ = Unix.select [ fd ] [] [] 1. in
                  assert (readable = [ fd ]);
                  let byte = Bytes.create 1 in
                  assert (Unix.read fd byte 0 1 = 1)))
        in
        Mutex.protect mutex (fun () ->
            while not !borrowed do
              Condition.wait ready mutex
            done);
        worker)
  in
  Domain.join worker;
  Alcotest.(check int)
    "token descriptors released after the waiter" before
    (Array.length (Sys.readdir "/proc/self/fd"))

let environment_records () =
  let module E = Libtmux_unix__Environment_io in
  let decode = E.decode ~dialect:Libtmux__Protocol.Metadata.Raw in
  let invalid text =
    match decode text with
    | Error _ -> ()
    | Ok _ -> Alcotest.fail "malformed environment accepted"
  in
  List.iter invalid
    [
      "A=\"abc";
      "A=\"abc\"; export B;\n";
      "A=\"\\q\"; export A;\n";
      "A=\"\000\"; export A;\n";
      "A=\"x\"; export A;\nA=\"y\"; export A;\n";
      "unset A;\nunset A;\n";
      "1A=\"x\"; export 1A;\n";
      "unset A;\n%end 1 2 3\n";
      "A=\"" ^ String.make 65_537 'x' ^ "\"; export A;\n";
    ];
  assert (decode "" = Ok (Iarray.of_list []));
  assert (
    decode "A=\"\"; export A;\nunset B;\n"
    = Ok
        (Iarray.of_list
           Environment.
             [
               { name = "A"; value = Value "" }; { name = "B"; value = Removed };
             ]))

let option_records () =
  let decode =
    Libtmux_unix__Options_io.decode ~version:"3.3"
      ~dialect:Libtmux__Protocol.Metadata.Raw
  in
  List.iter
    (fun text -> failure (fun () -> decode text))
    [
      "@x \"a\"b\"\n";
      "@x unquoted space\n";
      "status on\000\n";
      "@x \"\\000\"\n";
      "@x \"\\400\"\n";
      "@x 'truncated\n";
      "@x a\n@x b\n";
      "mouse maybe\n";
      "repeat-time 9223372036854775808\n";
      "update-environment[1] A\nupdate-environment[1] B\n";
      "update-environment\nupdate-environment[1] A\n";
      "mouse[1] on\n";
      "update-environment[2147483648] A\n";
    ];
  assert (Iarray.length (decode "") = 0);
  let rows = decode "update-environment*\n" in
  assert (Iarray.length rows = 1);
  let row = Iarray.get rows 0 in
  assert row.inherited;
  assert (row.value = Options.Array (Iarray.of_list []))

let () =
  Alcotest.run "native resources"
    [
      ( "contracts",
        [
          Alcotest.test_case "file identity, size and ownership" `Quick
            capture_identity;
          Alcotest.test_case "aggregate reservations" `Quick payload_budget;
          Alcotest.test_case "ready I/O observes deadlines" `Quick
            ready_deadline;
          Alcotest.test_case "token scope outlives a borrowed descriptor" `Quick
            cancellation_lifetime;
          Alcotest.test_case "environment records and limits" `Quick
            environment_records;
          Alcotest.test_case "option records and limits" `Quick option_records;
        ] );
    ]
