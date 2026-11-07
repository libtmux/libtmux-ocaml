open Libtmux
open Runtime_io

let arguments ~binary ~read_only ~update_environment endpoint session =
  if binary = "" || String.contains binary '\000' then
    fail (Error.Invalid_input "expected a tmux executable");
  let target = Session.Id.to_string session in
  endpoint_arguments ~binary endpoint
  @ [ "attach-session" ]
  @ (if read_only then [ "-r" ] else [])
  @ (if update_environment then [] else [ "-E" ])
  @ [ "-t"; target ]

let exited = function
  | 0 -> ()
  | code ->
      fail
        (Error.Command_failed
           {
             command = "attach-session";
             message =
               Printf.sprintf "terminal client exited with status %d" code;
           })

let signaled signal =
  fail
    (Error.Disconnected
       (Printf.sprintf "terminal client exited from signal %d" signal))

let attach_current ?cancel ?(binary = "tmux") ?(read_only = false)
    ?(update_environment = false) ?(stdin = Unix.stdin) ?(stdout = Unix.stdout)
    ?(stderr = Unix.stderr) endpoint ~session =
  protect (fun () ->
      let arguments =
        arguments ~binary ~read_only ~update_environment endpoint session
      in
      if not (Unix.isatty stdin) then
        fail
          (Error.Invalid_input "terminal attachment requires a terminal stdin");
      let run cancel_fd =
        let check () =
          if Option.exists Cancellation.is_cancelled cancel then
            raise Cancellation.Cancelled
        in
        check ();
        let pid =
          Unix.create_process_env binary (Array.of_list arguments)
            (environment ()) stdin stdout stderr
        in
        let reaped = ref false and descriptor = ref None in
        Fun.protect
          ~finally:(fun () ->
            Option.iter close_fd !descriptor;
            if not !reaped then terminate pid)
          (fun () ->
            let pidfd = Linux.pidfd_open pid in
            descriptor := Some pidfd;
            let rec wait () =
              check ();
              if Linux.pidfd_alive pidfd then (
                (try
                   ignore
                     (Unix.select
                        (pidfd :: Option.to_list cancel_fd)
                        [] [] (-1.))
                 with Unix.Unix_error (Unix.EINTR, _, _) -> ());
                wait ())
            in
            wait ();
            let _, status = Unix.waitpid [] pid in
            reaped := true;
            check ();
            match status with
            | Unix.WEXITED code -> exited code
            | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> signaled signal)
      in
      match cancel with
      | None -> run None
      | Some token -> Cancellation.borrow token (fun fd -> run (Some fd)))
