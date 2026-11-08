open Libtmux

let editors : Pane.t Expr.t =
  Expr.all
    [
      Expr.Bool.is_true Pane.Fields.active;
      Expr.Text.is_in Pane.Fields.current_command [ "nvim"; "vim" ];
      Expr.Int.ge Pane.Fields.width 120;
    ]

let () =
  print_endline (Expr.describe editors);
  match Query.exactly_one (List.to_seq [ "%1"; "%1" ]) with
  | Error (Cardinality.Multiple_matches { at_least }) ->
      Printf.printf "ambiguous: at least %d entries\n" at_least
  | _ -> failwith "duplicate entries must count separately"
