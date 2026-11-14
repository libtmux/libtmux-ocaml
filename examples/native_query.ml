(* docs:begin native-filter *)
open Libtmux

let active_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq |> Seq.filter Pane.active
  |> Seq.map Pane.id |> List.of_seq
(* docs:end native-filter *)

(* docs:begin typed-filter *)
let roomy_terminals : Pane.t Expr.t =
  Expr.all
    [
      Expr.Bool.is_true Pane.Fields.active;
      Expr.Text.is_in Pane.Fields.current_command
        [ "cat"; "bash"; "zsh"; "nvim" ];
      Expr.Int.ge Pane.Fields.width 80;
    ]

let roomy_ids snapshot =
  Snapshot.panes snapshot |> Iarray.to_seq
  |> Query.matching roomy_terminals
  |> Seq.map Pane.id |> List.of_seq
(* docs:end typed-filter *)

(* docs:begin relationship-filter *)
let sessions_with_room snapshot =
  let expression =
    Expr.Rel.any Session.Relations.windows
      (Expr.Rel.any Window.Relations.panes roomy_terminals)
  in
  Snapshot.sessions snapshot |> Iarray.to_seq |> Query.matching expression
  |> Seq.map Session.name |> List.of_seq
(* docs:end relationship-filter *)

module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let () =
  if Array.length Sys.argv <> 3 then (
    prerr_endline "usage: native_query TMUX_BINARY SOCKET_PATH";
    exit 2);
  let client =
    get
      (Client.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2)))
  in
  let snapshot =
    Fun.protect
      ~finally:(fun () -> get (Client.close client))
      (fun () -> get (Client.capture client))
  in
  let ids values = List.map Pane.Id.to_string values |> String.concat "," in
  Printf.printf "active=%s\nroomy=%s\nsessions=%s\n"
    (ids (active_ids snapshot))
    (ids (roomy_ids snapshot))
    (String.concat "," (sessions_with_room snapshot))
