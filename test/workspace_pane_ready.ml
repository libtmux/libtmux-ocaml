(* Signal from the final pane executable: a shell marker before exec does not
   establish stable process metadata for a window captured through two links. *)
let () =
  let binary = Sys.argv.(1) and socket = Sys.argv.(2) in
  let environment =
    Unix.environment () |> Array.to_seq
    |> Seq.filter (fun entry ->
        not
          (String.starts_with ~prefix:"TMUX=" entry
          || String.starts_with ~prefix:"TMUX_PANE=" entry))
    |> Array.of_seq
  in
  let pid =
    Unix.create_process_env binary
      [| binary; "-S"; socket; "wait-for"; "-S"; "workspace-pane-ready" |]
      environment Unix.stdin Unix.stdout Unix.stderr
  in
  assert (snd (Unix.waitpid [] pid) = Unix.WEXITED 0);
  let buffer = Bytes.create 4096 in
  let rec echo () =
    match Unix.read Unix.stdin buffer 0 (Bytes.length buffer) with
    | 0 -> ()
    | count ->
        let rec write offset =
          if offset < count then
            write
              (offset + Unix.write Unix.stdout buffer offset (count - offset))
        in
        write 0;
        echo ()
  in
  echo ()
