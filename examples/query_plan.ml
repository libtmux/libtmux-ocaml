open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let show name expression =
  let plan = get (Plan.panes expression) in
  Printf.printf "%s: %s\n" name (Plan.explanation plan);
  Printf.printf "  source filter: %s\n"
    (Option.value (Plan.source_filter plan) ~default:"nothing");
  Printf.printf "  local filter: %s\n" (Expr.describe (Plan.residual plan))

let () =
  let active : Pane.t Expr.t = Expr.Bool.is_true Pane.Fields.active in
  let editors : Pane.t Expr.t =
    Expr.all
      [ active; Expr.Text.is_in Pane.Fields.current_command [ "nvim"; "vim" ] ]
  in
  show "active" active;
  show "editors" editors;
  match Plan.panes ~pushdown:Plan.Require_exact editors with
  | Error error -> Format.printf "rejected: %a@." Error.pp error
  | Ok _ -> failwith "an inexact plan was accepted"
