(* A tmux daemon the caller owns for one scope. It runs in the foreground as a
   child (tmux -D), so the owned-process machinery signals and reaps it and its
   output pipes close when it exits. -D also turns exit-empty off: the daemon
   stays alive with no session. *)
open Libtmux
open Runtime_io

let prefix = "libtmux-ocaml-"
let socket_name = "server"

(* sun_path is 108 bytes including the terminator. *)
let sun_path_limit = 107

type probe = Answers | Absent | Refused

let probe socket =
  let fd = Unix.socket ~cloexec:true Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> close_fd fd)
    (fun () ->
      Unix.set_nonblock fd;
      match Unix.connect fd (Unix.ADDR_UNIX socket) with
      | () -> Answers
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EINPROGRESS), _, _) ->
          (* A full backlog still means a listener. *)
          Answers
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Absent
      | exception Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Refused)

(* Read what the daemon printed so far. [true] means end of file: the daemon
   exited and closed the pipe. *)
let drain fd output =
  let chunk = Bytes.create 4096 in
  let rec loop () =
    match Unix.read fd chunk 0 (Bytes.length chunk) with
    | 0 -> true
    | count ->
        if Buffer.length output < 4096 then
          Buffer.add_subbytes output chunk 0 count;
        loop ()
    | exception
        Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
        false
  in
  loop ()

(* Wait for the daemon's socket to answer. The directory watch wakes the wait
   when the socket appears; the short retry covers the instant between bind and
   listen, which raises no filesystem event. *)
let await_ready io (process : process) ~socket ~watch ~deadline =
  let printed = Buffer.create 256 in
  let rec loop () =
    match probe socket with
    | Answers -> ()
    | state ->
        let retry =
          if state = Refused then min deadline (Linux.now () +. 0.002)
          else deadline
        in
        (try
           io.wait
             ~read:[ watch; process.output; process.error ]
             ~write:[] ~deadline:retry
         with Failure Error.Deadline_exceeded when retry < deadline -> ());
        ignore (drain watch (Buffer.create 0));
        let closed =
          drain process.output printed || drain process.error printed
        in
        if closed && probe socket <> Answers then
          fail
            (Error.Disconnected
               ("private tmux daemon exited during startup: "
               ^ String.trim (Buffer.contents printed)));
        io.check ();
        loop ()
  in
  loop ()

let remove_directory directory =
  Array.iter
    (fun name -> Sys.remove (Filename.concat directory name))
    (Sys.readdir directory);
  Unix.rmdir directory

let create_directory root =
  let root =
    if Filename.is_relative root then Filename.concat (Sys.getcwd ()) root
    else root
  in
  let predicted =
    String.length root + 1 + String.length prefix + 6 + 1
    + String.length socket_name
  in
  if predicted > sun_path_limit then
    fail
      (Error.Invalid_input
         "root is too long for a Unix socket path (limit 107 bytes)");
  try Filename.temp_dir ~temp_dir:root ~perms:0o700 prefix ""
  with Sys_error message ->
    fail (Error.Filesystem { operation = "mkdir"; message })

(* A process the dead daemon started can hold its listening socket for a
   moment after the reap, so give an answering socket a short, bounded time to
   go quiet before calling it a failure. *)
let await_silent io ~socket =
  let deadline = Linux.now () +. 2. in
  let rec loop pause =
    probe socket <> Answers
    || Linux.now () < deadline
       &&
       ((try
           io.wait ~read:[] ~write:[]
             ~deadline:(min deadline (Linux.now () +. pause))
         with Failure Error.Deadline_exceeded -> ());
        loop (Float.min 0.05 (pause *. 2.)))
  in
  loop 0.002

(* Stop the child, require that nothing answers, then remove the directory.
   Any earlier failure keeps the directory: the daemon may still be running
   under it. *)
let stop io (process : process option) ~directory ~socket =
  Cleanup.run [ (fun () -> Option.iter (fun p -> p.stop ()) process) ];
  if not (await_silent io ~socket) then
    fail
      (Error.Filesystem
         {
           operation = "stop private daemon";
           message =
             "a daemon still answers at " ^ socket ^ "; kept " ^ directory;
         });
  Cleanup.step io.cleanup Remove_directory (fun () ->
      remove_directory directory)

(* Give the daemon one session so a client can attach. The control client that
   creates it closes again; the daemon stays up because exit-empty is off. *)
let seed io ~binary ~timeout ~endpoint ~name =
  let created = Bootstrap.create () in
  let connection, _ =
    Bootstrap.start created ~timeout ~io ~binary ~endpoint ~name
      ~window_name:"main"
      ~spawn:(Spawn.make (Exec { program = "/bin/cat"; args = [ "-u" ] }))
      ~width:80 ~height:24 ()
  in
  Connection.close connection

let run ~io ~finalize ~binary ?config_file ?root ?session ?(timeout = 5.) f =
  if (not (Float.is_finite timeout)) || timeout <= 0. then
    fail (Error.Invalid_input "timeout must be finite and positive");
  let directory =
    create_directory
      (match root with
      | Some root -> root
      | None -> Filename.get_temp_dir_name ())
  in
  let socket = Filename.concat directory socket_name in
  let process = ref None in
  Cleanup.protect
    ~finally:(fun () ->
      finalize (fun () -> stop io !process ~directory ~socket))
    (fun () ->
      let deadline = Linux.now () +. timeout in
      let watch = Linux.inotify_watch directory in
      Fun.protect
        ~finally:(fun () -> close_fd watch)
        (fun () ->
          let spawned =
            io.spawn
              [
                binary;
                "-D";
                "-S";
                socket;
                "-f";
                Option.value config_file ~default:"/dev/null";
              ]
          in
          process := Some spawned;
          await_ready io spawned ~socket ~watch ~deadline);
      let endpoint = Endpoint.socket_path socket in
      Option.iter (fun name -> seed io ~binary ~timeout ~endpoint ~name) session;
      f endpoint)
