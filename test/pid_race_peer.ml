open Libtmux

let () =
  let before = Array.length (Sys.readdir "/proc/self/fd") in
  let result =
    Libtmux_unix.Client.connect ~binary:Sys.argv.(1)
      (Endpoint.socket_path "/tmp/libtmux-ocaml-fault-peer")
  in
  (match result with
  | Ok client when Sys.getenv "LIBTMUX_TEST_PID_RACE" = "malformed-after-write"
    ->
      let get = function Ok value -> value | Error _ -> assert false in
      let op =
        get (Libtmux_unix.Client.submit client (Operations.signal "written"))
      in
      assert (
        match Libtmux_unix.Client.await op with
        | Error (Error.Outcome_unknown _) -> true
        | _ -> false);
      assert (
        match get (Libtmux_unix.Operation.inspect op) with
        | Outcome_unknown _ -> true
        | _ -> false);
      ignore (get (Libtmux_unix.Client.close client))
  | Error (Error.Disconnected _ | Error.Unsupported_binding _)
    when Sys.getenv "LIBTMUX_TEST_PID_RACE" <> "malformed-after-write" ->
      ()
  | _ -> assert false);
  assert (Array.length (Sys.readdir "/proc/self/fd") = before);
  print_endline "PASS binding race"
