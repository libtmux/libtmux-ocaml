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
            is_open = (fun () -> true);
            await = (fun f -> f ());
            stop = (fun () -> ());
          }
      in
      let deadline = Libtmux_unix__Linux.now () -. 1. in
      let expired f =
        match Io.protect f with
        | Error Error.Deadline_exceeded -> ()
        | _ -> Alcotest.fail "ready I/O bypassed the deadline"
      in
      expired (fun () -> Io.read (Io.blocking ()) process ~pidfd:None ~deadline);
      expired (fun () ->
          Io.write (Io.blocking ()) process ~pidfd:None ~deadline "late"))

let high_descriptor_readiness () =
  let owned = ref [] in
  let keep fd =
    owned := fd :: !owned;
    fd
  in
  Fun.protect
    ~finally:(fun () -> List.iter Unix.close !owned)
    (fun () ->
      for _ = 1 to 1100 do
        ignore
          (keep (Unix.openfile "/dev/null" [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0))
      done;
      let reader, writer = Unix.pipe ~cloexec:true () in
      ignore (keep reader);
      ignore (keep writer);
      let deadline () = Libtmux_unix__Linux.now () +. 0.1 in
      Io.wait ~read:[] ~write:[ writer ] ~deadline:(deadline ());
      ignore (Unix.write_substring writer "x" 0 1);
      Io.wait ~read:[ reader ] ~write:[] ~deadline:(deadline ());
      let byte = Bytes.create 1 in
      Alcotest.(check int) "ready high descriptor" 1 (Unix.read reader byte 0 1);
      match
        Io.protect (fun () ->
            Io.wait ~read:[ reader ] ~write:[]
              ~deadline:(Libtmux_unix__Linux.now () +. 0.001))
      with
      | Error Error.Deadline_exceeded -> ()
      | _ -> Alcotest.fail "unready high descriptor did not reach its deadline")

let shutdown_failure_reaps () =
  let reaped = ref false in
  (match
     Io.shutdown
       ~cleanup:(Libtmux_unix.Cleanup.create ())
       ~exited:(fun () -> true)
       ~signal:(fun value -> if value = Sys.sigkill then raise Exit)
       ~await_grace:(fun _ -> false)
       ~await:(fun () -> reaped := true)
   with
  | () -> Alcotest.fail "forced-termination failure disappeared"
  | exception (Exit | Fun.Finally_raised Exit) -> ());
  Alcotest.(check bool) "reaping attempted after signal failure" true !reaped

exception Setup_failure
exception Cleanup_failure

let setup_primary_failure () =
  let cleanup = Libtmux_unix.Cleanup.create () in
  let process =
    Io.
      {
        input = Unix.stdin;
        output = Unix.stdout;
        error = Unix.stderr;
        is_open = (fun () -> true);
        await = (fun f -> f ());
        stop =
          (fun () ->
            Libtmux_unix__Cleanup.step cleanup Close_pipe (fun () ->
                raise Cleanup_failure));
      }
  in
  let io = { (Io.blocking ~cleanup ()) with spawn = (fun _ -> process) } in
  match
    Libtmux_unix__Connection.connect_process ~io ~binary:"unused" ~arguments:[]
      ~initial:(fun _ ~deadline:_ -> raise Setup_failure)
      (Endpoint.named_socket "libtmux-ocaml-unopened")
  with
  | _ -> Alcotest.fail "failed connection returned"
  | exception Setup_failure ->
      let report = Result.get_ok (Libtmux_unix.Cleanup.inspect cleanup) in
      Alcotest.(check int)
        "secondary setup failure retained" 1
        (Iarray.length report.issues);
      assert ((Iarray.get report.issues 0).exception_ = Cleanup_failure)

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
    Libtmux_unix__Options_io.decode ~version:"3.3a"
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

let incremental_bytes () =
  let module Pattern = Libtmux_unix__Byte_pattern in
  let pattern = Pattern.create "ababac" in
  Alcotest.(check (option int)) "prefix alone" None (Pattern.feed pattern "aba");
  Alcotest.(check (option int))
    "overlap crosses chunk boundary" (Some 4)
    (Pattern.feed pattern "babac");
  let binary = Pattern.create "ab\000cd" in
  Alcotest.(check (option int)) "NUL prefix" None (Pattern.feed binary "ab\000");
  Alcotest.(check (option int))
    "NUL-spanning match" (Some 1) (Pattern.feed binary "cd");
  let contains text needle =
    let rec scan offset =
      offset + String.length needle <= String.length text
      && (String.sub text offset (String.length needle) = needle
         || scan (offset + 1))
    in
    scan 0
  in
  let property (needle, body, embedded) =
    let needle = needle ^ "x" in
    let text = if embedded then body ^ needle ^ body else body in
    let split = String.length text / 2 in
    let pattern = Pattern.create needle in
    let matched =
      Option.is_some (Pattern.feed pattern (String.take_first split text))
      || Option.is_some (Pattern.feed pattern (String.drop_first split text))
    in
    Bool.equal matched (contains text needle)
  in
  QCheck2.Test.check_exn
    ~rand:(Random.State.make [| 2026; 11; 7 |])
    (QCheck2.Test.make
       ~name:"incremental bytes agree with native substring matching"
       ~print:(fun (needle, body, embedded) ->
         Printf.sprintf "needle=%S body=%S embedded=%b" needle body embedded)
       ~count:1000
       QCheck2.Gen.(triple string_small string_small bool)
       property)

let coalesced_observation () =
  let generation = Io.get (Generation.of_string (String.make 64 'a')) in
  let data offset =
    Output.Data { cursor = { generation; offset }; bytes = "x" }
  in
  let pp formatter = function
    | Output.Data { cursor; bytes } ->
        Format.fprintf formatter "Data(%Ld,%S)" cursor.offset bytes
    | Gap { reason; _ } ->
        Format.fprintf formatter "Gap(%a)" Output.reason_pp reason
    | End reason -> Format.fprintf formatter "End(%a)" Output.reason_pp reason
  in
  let event_type = Alcotest.testable pp ( = ) in
  let pending = Queue.create () in
  List.iter (fun event -> Queue.add event pending) [ data 2L; data 3L ];
  let event =
    Libtmux_unix__Observation_wait.coalesce
      ~poll:(fun () -> Queue.take_opt pending)
      (Some (data 1L))
  in
  Alcotest.(check (option event_type))
    "one recapture covers queued data"
    (Some (data 3L))
    event;
  let gap =
    Output.Gap { after = None; lost_bytes = None; reason = Membership_changed }
  in
  List.iter
    (fun event -> Queue.add event pending)
    [ gap; End Membership_changed ];
  let event =
    Libtmux_unix__Observation_wait.coalesce
      ~poll:(fun () -> Queue.take_opt pending)
      (Some (data 4L))
  in
  Alcotest.(check (option event_type))
    "coverage loss precedes recapture" (Some gap) event;
  Alcotest.(check int) "terminal event retained" 1 (Queue.length pending)

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
          Alcotest.test_case "high-descriptor readiness and deadline" `Quick
            high_descriptor_readiness;
          Alcotest.test_case "signal failure still attempts reaping" `Quick
            shutdown_failure_reaps;
          Alcotest.test_case "setup error survives a cleanup failure" `Quick
            setup_primary_failure;
          Alcotest.test_case "token scope outlives a borrowed descriptor" `Quick
            cancellation_lifetime;
          Alcotest.test_case "environment records and limits" `Quick
            environment_records;
          Alcotest.test_case "option records and limits" `Quick option_records;
          Alcotest.test_case "incremental byte matching" `Quick
            incremental_bytes;
          Alcotest.test_case "coalesced observation invalidation" `Quick
            coalesced_observation;
        ] );
    ]
