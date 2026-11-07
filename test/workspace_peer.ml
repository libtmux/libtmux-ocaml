open Libtmux
module C = Libtmux_unix.Client
module W = Libtmux_unix.Workspace

module Exercise = Workspace_scenarios.Make (struct
  module C = struct
    include C

    let connect ~binary endpoint = C.connect ~binary endpoint
    let capture client = C.capture client
    let run client command = C.run client command
  end

  module W = struct
    include W

    let submit_bootstrap ~binary plan = W.submit_bootstrap ~binary plan

    let await ?compensate_on_failure operation =
      W.await ?compensate_on_failure operation
  end

  let read_line = read_line

  let cancel operation =
    Libtmux_unix.Cancellation.with_ (fun cancel ->
        let sender =
          Domain.spawn (fun () ->
              assert (read_line () = "cancel");
              Libtmux_unix.Cancellation.cancel cancel;
              print_endline "CANCELLED_SIGNAL")
        in
        Fun.protect
          ~finally:(fun () -> Domain.join sender)
          (fun () ->
            match Libtmux_unix.Workspace.await ~cancel operation with
            | _ -> failwith "workspace cancellation did not propagate"
            | exception Libtmux_unix.Cancellation.Cancelled -> ()))
end)

let () =
  let binary = Sys.argv.(1) and endpoint = Endpoint.socket_path Sys.argv.(2) in
  if Array.length Sys.argv = 5 && Sys.argv.(3) = "--bootstrap" then
    Exercise.run_bootstrap ~binary ~endpoint ~version:Sys.argv.(4)
  else Exercise.run ~binary ~endpoint
