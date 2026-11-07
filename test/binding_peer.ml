open Libtmux
module C = Libtmux_unix__Connection
module Io = Libtmux_unix__Runtime_io

let () =
  let client =
    C.connect ~binary:Sys.argv.(1) ~io:Io.blocking
      (Endpoint.socket_path Sys.argv.(2))
  in
  Fun.protect
    ~finally:(fun () -> C.close client)
    (fun () ->
      C.with_auxiliary client (fun _ -> ());
      print_endline "READY";
      ignore (read_line ());
      let result =
        Io.protect (fun () -> C.with_auxiliary client (fun _ -> ()))
      in
      assert (match result with Error Error.Stale_target -> true | _ -> false);
      assert client.closed;
      print_endline "REJECT replacement")
