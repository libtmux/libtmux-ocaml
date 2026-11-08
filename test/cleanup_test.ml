module Cleanup = Libtmux_unix.Cleanup
module Internal = Libtmux_unix__Cleanup
module Io = Libtmux_unix__Runtime_io

exception Primary
exception Secondary

let snapshot report = Result.get_ok (Cleanup.inspect report)

let preserve_primary () =
  let report = Cleanup.create () and released = ref false in
  let original = ref "" in
  (match
     Internal.protect
       ~finally:(fun () ->
         Internal.run
           [
             (fun () ->
               Internal.step report Close_pipe (fun () -> raise Secondary));
             (fun () -> released := true);
           ])
       (fun () ->
         try raise Primary
         with exn ->
           let bt = Printexc.get_raw_backtrace () in
           original := Printexc.raw_backtrace_to_string bt;
           Printexc.raise_with_backtrace exn bt)
   with
  | () -> Alcotest.fail "primary failure disappeared"
  | exception Primary ->
      let actual = Printexc.get_backtrace () in
      Alcotest.(check bool)
        "original raise site preserved" true
        (String.starts_with ~prefix:!original actual));
  Alcotest.(check bool) "independent finalizer ran" true !released;
  let issues = (snapshot report).issues in
  Alcotest.(check int) "one cleanup issue" 1 (Iarray.length issues);
  assert ((Iarray.get issues 0).exception_ = Secondary)

let native_cancellation () =
  let report = Cleanup.create () in
  let cleanup () =
    Internal.step report Close_pipe (fun () -> raise Secondary)
  in
  (match
     Internal.protect ~finally:cleanup (fun () ->
         raise Libtmux_unix.Cancellation.Cancelled)
   with
  | () -> Alcotest.fail "blocking cancellation disappeared"
  | exception Libtmux_unix.Cancellation.Cancelled -> ());
  Eio_main.run (fun _ ->
      match
        Eio.Cancel.sub (fun scope ->
            Eio.Cancel.cancel scope Primary;
            Internal.protect
              ~finally:(fun () -> Eio.Cancel.protect cleanup)
              Eio.Fiber.check)
      with
      | () -> Alcotest.fail "Eio cancellation disappeared"
      | exception Eio.Cancel.Cancelled Primary -> ());
  let issues = (Result.get_ok (Libtmux_eio.Cleanup.inspect report)).issues in
  Alcotest.(check int)
    "both cancellation cleanups retained" 2 (Iarray.length issues)

let report_bounds () =
  let report = Cleanup.create () in
  let leaf () =
    Internal.step report Close_pipe (fun () -> Io.fail Libtmux.Error.Closed)
  in
  (try Internal.run [ (fun () -> Internal.run [ leaf; leaf ]) ]
   with Io.Failure _ -> ());
  let first = snapshot report in
  Alcotest.(check int)
    "nested composition records each leaf once" 2
    (Iarray.length first.issues);
  Iarray.iter
    (fun issue -> assert (issue.Cleanup.error = Some Libtmux.Error.Closed))
    first.issues;
  for _ = 1 to 65 do
    try Internal.step report Reap (fun () -> raise Secondary)
    with Secondary -> ()
  done;
  let final = snapshot report in
  Alcotest.(check int)
    "bounded retained incidents" 64
    (Iarray.length final.issues);
  Alcotest.(check int) "overflow counted" 3 final.omitted;
  Alcotest.(check int) "previous array unchanged" 2 (Iarray.length first.issues);
  let foreign = Domain.join (Domain.spawn (fun () -> Cleanup.inspect report)) in
  assert (foreign = Error Libtmux.Error.Wrong_domain)

let failed_kill () =
  let report = Cleanup.create () and reaped = ref false in
  (match
     Io.shutdown ~cleanup:report
       ~exited:(fun () -> false)
       ~signal:(fun signal -> if signal = Sys.sigkill then raise Secondary)
       ~await_grace:(fun _ -> false)
       ~await:(fun () -> reaped := true)
   with
  | () -> Alcotest.fail "failed KILL reported success"
  | exception Secondary -> ());
  Alcotest.(check bool) "no blocking reap of an unconfirmed exit" false !reaped;
  let issues = (snapshot report).issues in
  Alcotest.(check int)
    "signal and unreaped-child evidence" 2 (Iarray.length issues);
  assert ((Iarray.get issues 0).phase = Cleanup.Kill);
  assert ((Iarray.get issues 1).phase = Cleanup.Unreaped_child)

let () =
  Printexc.record_backtrace true;
  Alcotest.run "cleanup diagnostics"
    [
      ( "contracts",
        [
          Alcotest.test_case "original exception and remaining finalizers"
            `Quick preserve_primary;
          Alcotest.test_case "native cancellation remains native" `Quick
            native_cancellation;
          Alcotest.test_case "typed incidents, nesting, bounds and domain"
            `Quick report_bounds;
          Alcotest.test_case "failed KILL does not wait indefinitely" `Quick
            failed_kill;
        ] );
    ]
