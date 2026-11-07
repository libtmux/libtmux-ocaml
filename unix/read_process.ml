open Libtmux
open Runtime_io
module C = Connection

(* Only read commands may use this route. PID verification happens after the
   command because a command client's stdout has no control framing. *)
let run c name arguments decode =
  if not (List.mem name [ "show-environment"; "show-options"; "show-hooks" ])
  then invalid_arg "Read_process.run: unregistered read command";
  C.check c;
  let marker = "libtmux-ocaml-read-" ^ Linux.nonce () in
  let encoded =
    List.map (fun value -> protocol (C.P.Command.argv_argument value)) arguments
  in
  let argv =
    Runtime_io.endpoint_arguments ~binary:c.C.binary (Source.endpoint c.source)
    @ [ "display-message"; "-p"; "#{pid}"; ";"; name ]
    @ encoded
    @ [ ";"; "display-message"; "-p"; marker ]
  in
  C.Budget.during c.budget
    (16 * 1024 * 1024)
    (fun () ->
      C.with_process c argv (fun lane ->
          let stdout, stderr =
            Runtime_io.collect lane.io lane.process ~pidfd:c.pidfd
              ~deadline:(Linux.now () +. c.timeout)
          in
          let expected = Int.to_string (Source.server_pid c.source) ^ "\n" in
          if
            not
              (String.starts_with ~prefix:expected stdout
              && Linux.pidfd_alive c.pidfd)
          then (
            C.close c;
            fail Error.Stale_target);
          if stderr <> "" then
            fail (Error.Command_failed { command = name; message = stderr });
          let ending = marker ^ "\n" in
          if
            String.length stdout < String.length expected + String.length ending
            || not (String.ends_with ~suffix:ending stdout)
          then fail (Error.Malformed_data "incomplete read process result");
          decode
            (String.sub stdout (String.length expected)
               (String.length stdout - String.length expected
              - String.length ending))))
