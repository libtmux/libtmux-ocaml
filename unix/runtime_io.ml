open Libtmux

exception Failure = Cleanup.Failure

let fail error = raise (Failure error)
let get = function Ok value -> value | Error error -> fail error

let protocol ?(limit = 4 * 1024 * 1024) = function
  | Ok value -> value
  | Error (Libtmux__Protocol.Malformed text) -> fail (Error.Malformed_data text)
  | Error (Libtmux__Protocol.Limit text) ->
      fail (Error.Capacity { resource = text; limit })

let protect f =
  try Ok (f ()) with
  | Failure error -> Error error
  | Unix.Unix_error (error, operation, _) ->
      Error (Error.Disconnected (operation ^ ": " ^ Unix.error_message error))

type process = {
  input : Unix.file_descr;
  output : Unix.file_descr;
  error : Unix.file_descr;
  is_open : unit -> bool;
  await : (unit -> unit) -> unit;
  stop : unit -> unit;
}

type t = {
  cleanup : Cleanup.t;
  spawn : string list -> process;
  file_io : 'a. (unit -> 'a) -> 'a;
  check : unit -> unit;
  wait :
    read:Unix.file_descr list ->
    write:Unix.file_descr list ->
    deadline:float ->
    unit;
}

let environment () =
  Unix.environment () |> Array.to_list
  |> List.filter (fun entry ->
      not
        (String.starts_with ~prefix:"TMUX=" entry
        || String.starts_with ~prefix:"TMUX_PANE=" entry))
  |> Array.of_list

let rec wait ~read ~write ~deadline =
  let remaining = deadline -. Linux.now () in
  if remaining <= 0. then fail Error.Deadline_exceeded;
  let ready =
    try Linux.poll ~read ~write ~timeout:remaining
    with Unix.Unix_error (Unix.EINTR, _, _) -> false
  in
  (* A poll timeout can be capped by the platform; only the absolute deadline
     establishes expiry. EINTR uses the same recomputation. *)
  if not ready then wait ~read ~write ~deadline

let close_fd fd =
  try Unix.close fd with Unix.Unix_error (Unix.EBADF, _, _) -> ()

let shutdown_grace = 0.2

let shutdown ~cleanup ~exited ~signal ~await_grace ~await =
  let finished = ref false in
  Cleanup.protect
    ~finally:(fun () ->
      if !finished then Cleanup.step cleanup Reap await
      else
        match Cleanup.attempt cleanup Kill (fun () -> signal Sys.sigkill) with
        | Ok () -> Cleanup.step cleanup Reap await
        | Error ((cause, bt) as failure) ->
            (* A failed signal cannot justify an unbounded reap of a live
               child. Check only for an exit already observed by the runtime. *)
            let status = Cleanup.attempt cleanup Reap exited in
            (match status with
            | Ok true -> ignore (Cleanup.attempt cleanup Reap await)
            | Ok false | Error _ ->
                Cleanup.record cleanup Unreaped_child cause bt);
            Cleanup.get (Error failure))
    (fun () ->
      Cleanup.step cleanup Terminate (fun () -> signal Sys.sigterm);
      finished :=
        Cleanup.step cleanup Grace (fun () -> await_grace shutdown_grace))

let cleanup_fd cleanup phase fd =
  Cleanup.step cleanup phase (fun () -> close_fd fd)

let terminate ?(cleanup = Cleanup.create ()) pid =
  Cleanup.check cleanup;
  (* Only the creator reaps this child, so its PID cannot be reused here. *)
  let reaped = ref false in
  let signal value =
    if not !reaped then
      try Unix.kill pid value with Unix.Unix_error (Unix.ESRCH, _, _) -> ()
  in
  let rec reap () =
    if not !reaped then
      try
        ignore (Unix.waitpid [] pid);
        reaped := true
      with Unix.Unix_error (Unix.EINTR, _, _) -> reap ()
  in
  let descriptor =
    match
      Cleanup.attempt cleanup Open_pidfd (fun () -> Linux.pidfd_open pid)
    with
    | Ok fd -> Some fd
    | Error (Unix.Unix_error _, _) -> None
    | Error failure -> Cleanup.get (Error failure)
  in
  let rec exited () =
    if !reaped then true
    else
      try
        let found, _ = Unix.waitpid [ Unix.WNOHANG ] pid in
        reaped := found <> 0;
        !reaped
      with Unix.Unix_error (Unix.EINTR, _, _) -> exited ()
  in
  Cleanup.protect
    ~finally:(fun () -> Option.iter (cleanup_fd cleanup Close_pidfd) descriptor)
    (fun () ->
      shutdown ~cleanup ~exited ~signal ~await:reap ~await_grace:(fun seconds ->
          match descriptor with
          | None -> false
          | Some pidfd -> (
              match
                protect (fun () ->
                    wait ~read:[ pidfd ] ~write:[]
                      ~deadline:(Linux.now () +. seconds))
              with
              | Ok () -> true
              | Error Error.Deadline_exceeded -> false
              | Error error -> fail error)))

let spawn ~cleanup arguments =
  Cleanup.check cleanup;
  let owned = ref [] in
  let child = ref None in
  let pipe () =
    let reader, writer = Unix.pipe ~cloexec:true () in
    owned := reader :: writer :: !owned;
    (reader, writer)
  in
  let release fd =
    close_fd fd;
    owned := List.filter (( <> ) fd) !owned
  in
  try
    let stdin, input = pipe ()
    and output, stdout = pipe ()
    and error, stderr = pipe () in
    let pid =
      Unix.create_process_env (List.hd arguments) (Array.of_list arguments)
        (environment ()) stdin stdout stderr
    in
    child := Some pid;
    release stdin;
    release stdout;
    release stderr;
    List.iter Unix.set_nonblock [ input; output; error ];
    let stopped = ref false in
    let finished = ref None in
    let stop () =
      if not !stopped then (
        stopped := true;
        finished :=
          Some
            (try
               Cleanup.run
                 (List.map
                    (fun fd () -> cleanup_fd cleanup Close_pipe fd)
                    [ input; output; error ]
                 @ [ (fun () -> terminate ~cleanup pid) ]);
               Ok ()
             with exn -> Error (exn, Printexc.get_raw_backtrace ())));
      Option.iter Cleanup.get !finished
    in
    {
      input;
      output;
      error;
      is_open = (fun () -> not !stopped);
      await =
        (fun f ->
          if !stopped then fail Error.Closed;
          f ());
      stop;
    }
  with exn ->
    let bt = Printexc.get_raw_backtrace () in
    Cleanup.protect
      ~finally:(fun () ->
        Cleanup.run
          (List.map (fun fd () -> cleanup_fd cleanup Close_pipe fd) !owned
          @ [ (fun () -> Option.iter (terminate ~cleanup) !child) ]))
      (fun () -> Printexc.raise_with_backtrace exn bt)

let blocking ?(cleanup = Cleanup.create ()) () =
  Cleanup.check cleanup;
  {
    cleanup;
    spawn = spawn ~cleanup;
    wait;
    file_io = (fun f -> f ());
    check = (fun () -> ());
  }

let check io ~deadline =
  io.check ();
  if Linux.now () >= deadline then fail Error.Deadline_exceeded

(* Runtime checks can yield, allowing close to recycle a descriptor meanwhile. *)
let check_process process = if not (process.is_open ()) then fail Error.Closed

let endpoint_arguments ?(start_server = false) ~binary endpoint =
  let endpoint =
    match Endpoint.kind endpoint with
    | Named_socket name -> [ "-L"; name ]
    | Socket_path path -> [ "-S"; path ]
  in
  [ binary; "-u" ] @ (if start_server then [] else [ "-N" ]) @ endpoint

let arguments ~binary endpoint =
  endpoint_arguments ~binary endpoint
  @ [ "-C"; "attach-session"; "-E"; "-f"; "no-output" ]

let write io process ~pidfd ~deadline bytes =
  let length = String.length bytes in
  let rec loop offset =
    if offset < length then (
      check io ~deadline;
      check_process process;
      Option.iter
        (fun fd ->
          if not (Linux.pidfd_alive fd) then
            fail (Error.Disconnected "bound daemon exited"))
        pidfd;
      try
        let count =
          Unix.write_substring process.input bytes offset (length - offset)
        in
        if count = 0 then
          fail (Error.Disconnected "control write made no progress");
        loop (offset + count)
      with
      | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          process.await (fun () ->
              io.wait ~read:(Option.to_list pidfd) ~write:[ process.input ]
                ~deadline);
          loop offset
      | Unix.Unix_error (Unix.EINTR, _, _) -> loop offset)
  in
  loop 0

let read io process ~pidfd ~deadline =
  let buffer = Bytes.create 65_536 in
  let rec loop () =
    check io ~deadline;
    check_process process;
    Option.iter
      (fun fd ->
        if not (Linux.pidfd_alive fd) then
          fail (Error.Disconnected "bound daemon exited"))
      pidfd;
    let available =
      try Unix.read process.output buffer 0 (Bytes.length buffer)
      with
      | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
        -1
    in
    if available = 0 then fail (Error.Disconnected "control connection closed")
    else if available > 0 then Bytes.sub_string buffer 0 available
    else
      let diagnostic =
        try Unix.read process.error buffer 0 (Bytes.length buffer)
        with
        | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
        ->
          -1
      in
      if diagnostic > 0 then
        fail (Error.Disconnected (Bytes.sub_string buffer 0 diagnostic));
      let watched =
        if diagnostic = 0 then [ process.output ]
        else [ process.output; process.error ]
      in
      process.await (fun () ->
          io.wait ~read:(watched @ Option.to_list pidfd) ~write:[] ~deadline);
      loop ()
  in
  loop ()

let collect io process ~pidfd ~deadline =
  let output = Buffer.create 256 and error = Buffer.create 256 in
  let chunk = Bytes.create 65_536 in
  let rec loop streams =
    check io ~deadline;
    check_process process;
    if not (Linux.pidfd_alive pidfd) then
      fail (Error.Disconnected "bound daemon exited");
    if streams <> [] then (
      let progressed = ref false in
      let pending =
        List.filter
          (fun (fd, buffer, limit) ->
            let count =
              try Unix.read fd chunk 0 (Bytes.length chunk)
              with
              | Unix.Unix_error
                  ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _)
              ->
                -1
            in
            if count = 0 then (
              progressed := true;
              false)
            else if count < 0 then true
            else (
              progressed := true;
              if count > limit - Buffer.length buffer then
                fail
                  (Error.Capacity { resource = "read process output"; limit });
              Buffer.add_subbytes buffer chunk 0 count;
              true))
          streams
      in
      if not !progressed then
        process.await (fun () ->
            io.wait
              ~read:(pidfd :: List.map (fun (fd, _, _) -> fd) pending)
              ~write:[] ~deadline);
      loop pending)
  in
  loop
    [
      (process.output, output, 4 * 1024 * 1024); (process.error, error, 65_536);
    ];
  (Buffer.contents output, Buffer.contents error)
