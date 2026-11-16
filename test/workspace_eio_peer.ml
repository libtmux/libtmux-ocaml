open Libtmux
module C = Libtmux_eio.Client
module W = Libtmux_eio.Workspace

exception Cancel_workspace

let () =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let input =
            Eio.Buf_read.of_flow ~max_size:64 (Eio.Stdenv.stdin env)
          in
          let read_line () = Eio.Buf_read.line input in
          let module Exercise = Workspace_scenarios.Make (struct
            module C = struct
              include C

              let connect ~binary endpoint =
                C.connect ~binary ~sw
                  ~process_mgr:(Eio.Stdenv.process_mgr env)
                  ~mono_clock:(Eio.Stdenv.mono_clock env)
                  endpoint
            end

            module W = struct
              include W

              let submit_bootstrap ?config_file ~binary plan =
                W.submit_bootstrap ?config_file ~binary ~sw
                  ~process_mgr:(Eio.Stdenv.process_mgr env)
                  ~mono_clock:(Eio.Stdenv.mono_clock env)
                  plan
            end

            let read_line = read_line

            let cancel operation =
              let cancelled = ref false in
              (try
                 Eio.Cancel.sub (fun scope ->
                     Eio.Fiber.pair
                       (fun () ->
                         ignore (W.await operation);
                         failwith "workspace cancellation did not propagate")
                       (fun () ->
                         assert (read_line () = "cancel");
                         Eio.Cancel.cancel scope Cancel_workspace;
                         print_endline "CANCELLED_SIGNAL")
                     |> ignore)
               with Eio.Cancel.Cancelled Cancel_workspace -> cancelled := true);
              assert !cancelled
          end) in
          let binary = Sys.argv.(1)
          and endpoint = Endpoint.socket_path Sys.argv.(2) in
          if Array.length Sys.argv >= 5 && Sys.argv.(3) = "--bootstrap" then
            let config_file =
              if Array.length Sys.argv > 5 then Some Sys.argv.(5) else None
            in
            Exercise.run_bootstrap ~config_file ~binary ~endpoint
              ~version:Sys.argv.(4)
          else Exercise.run ~binary ~endpoint))
