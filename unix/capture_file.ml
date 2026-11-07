open Libtmux
open Runtime_io

let max_bytes = 8 * 1024 * 1024

let protect_filesystem f =
  try f ()
  with Unix.Unix_error (error, operation, _) ->
    fail (Error.Filesystem { operation; message = Unix.error_message error })

type t = {
  directory : string;
  path : string;
  fd : Unix.file_descr;
  device : int;
  inode : int;
}

let validate_root root =
  if
    root = ""
    || root.[0] <> '/'
    || not
         (String.for_all
            (fun c ->
              (c >= 'a' && c <= 'z')
              || (c >= 'A' && c <= 'Z')
              || (c >= '0' && c <= '9')
              || String.contains "/_.-" c)
            root)
  then
    fail
      (Error.Invalid_input
         "scratch directory must be an absolute ASCII path without format \
          metacharacters")

let create root =
  protect_filesystem (fun () ->
      validate_root root;
      let directory =
        Filename.concat root ("libtmux-ocaml-" ^ Linux.nonce ())
      in
      Unix.mkdir directory 0o700;
      try
        let path = Filename.concat directory "capture" in
        let fd =
          Unix.openfile path
            [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
            0o600
        in
        try
          let stat = Unix.fstat fd in
          { directory; path; fd; device = stat.st_dev; inode = stat.st_ino }
        with exn ->
          Runtime_io.close_fd fd;
          Unix.unlink path;
          raise exn
      with exn ->
        Unix.rmdir directory;
        raise exn)

let same t stat =
  stat.Unix.st_kind = Unix.S_REG
  && stat.st_dev = t.device && stat.st_ino = t.inode

let cleanup t =
  protect_filesystem (fun () ->
      Runtime_io.close_fd t.fd;
      (try if same t (Unix.lstat t.path) then Unix.unlink t.path
       with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
      Unix.rmdir t.directory)

let read t ~expected =
  protect_filesystem (fun () ->
      if expected < 0 || expected > max_bytes then
        fail (Error.Capacity { resource = "capture file"; limit = max_bytes });
      if not (same t (Unix.lstat t.path) && same t (Unix.fstat t.fd)) then
        fail (Error.Capture_raced "capture file identity changed");
      if (Unix.fstat t.fd).st_size <> expected then
        fail
          (Error.Capture_raced "capture file length differs from buffer size");
      ignore (Unix.lseek t.fd 0 Unix.SEEK_SET);
      let bytes = Bytes.create (expected + 1) in
      let rec loop offset =
        if offset = expected + 1 then
          fail (Error.Capture_raced "capture file grew");
        let count =
          try Unix.read t.fd bytes offset (expected + 1 - offset)
          with Unix.Unix_error (Unix.EINTR, _, _) -> -1
        in
        if count < 0 then loop offset
        else if count = 0 then (
          if offset <> expected then
            fail (Error.Capture_raced "capture file was truncated");
          Bytes.sub_string bytes 0 offset)
        else loop (offset + count)
      in
      loop 0)
