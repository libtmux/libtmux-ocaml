(* A stand-in for the tmux binary in the outer tests and the benchmark
   drivers, started in place of tmux by the library or the CLI under test.
   Environment variables choose what it does:

   - [LIBTMUX_STANDIN_REPLY] set: print its value and exit 0, whatever the
     arguments. Nothing else runs.
   - Otherwise [LIBTMUX_STANDIN_TMUX] names the real tmux, which the stand-in
     runs with the same arguments. [LIBTMUX_STANDIN_CONFIG] adds [-f FILE]
     before them. [LIBTMUX_STANDIN_AUDIT] names a file that first receives the
     arguments as one space-separated line. [LIBTMUX_STANDIN_LAUNCHES] names a
     file that first receives this process's ID, which the real tmux keeps. *)

let append path line =
  let channel =
    open_out_gen [ Open_wronly; Open_append; Open_creat ] 0o600 path
  in
  output_string channel line;
  close_out channel

let record variable line =
  Option.iter (fun path -> append path line) (Sys.getenv_opt variable)

let () =
  let arguments = List.tl (Array.to_list Sys.argv) in
  match
    ( Sys.getenv_opt "LIBTMUX_STANDIN_REPLY",
      Sys.getenv_opt "LIBTMUX_STANDIN_TMUX" )
  with
  | Some reply, _ -> print_endline reply
  | None, Some real ->
      record "LIBTMUX_STANDIN_AUDIT" (String.concat " " arguments ^ "\n");
      record "LIBTMUX_STANDIN_LAUNCHES" (string_of_int (Unix.getpid ()) ^ "\n");
      let config =
        match Sys.getenv_opt "LIBTMUX_STANDIN_CONFIG" with
        | Some file -> [ "-f"; file ]
        | None -> []
      in
      Unix.execv real (Array.of_list ((real :: config) @ arguments))
  | None, None ->
      prerr_endline "tmux_standin: set LIBTMUX_STANDIN_REPLY or _TMUX";
      exit 2
