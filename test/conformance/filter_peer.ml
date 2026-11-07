open Libtmux
open Yojson.Safe.Util

let () =
  let fixture = Yojson.Safe.from_file Sys.argv.(1) in
  let integer row name = row |> member name |> to_int in
  let string row name = row |> member name |> to_string in
  let panes =
    fixture |> member "panes" |> to_list
    |> List.map (fun row ->
        Snapshot.Input.
          {
            id = Model_fixture.pane_id (string row "pane_id");
            window_id = Model_fixture.window_id "@1";
            index = integer row "pane_index";
            active = row |> member "pane_active" |> to_bool;
            dead = false;
            title = string row "pane_title";
            current_command = string row "pane_current_command";
            current_path = string row "pane_current_path";
            pid = None;
            width = integer row "pane_width";
            height = integer row "pane_height";
            left = integer row "pane_left";
            top = integer row "pane_top";
          })
  in
  let snapshot = Model_fixture.get (Model_fixture.make ~panes ()) in
  let codec = function
    | Ok value -> value
    | Error error ->
        failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error)
  in
  let results =
    fixture |> member "cases" |> to_list
    |> List.map (fun case ->
        let expression =
          codec (Libtmux_json.Expr.decode Model.pane (member "query" case))
        in
        let matches =
          Snapshot.panes snapshot |> Iarray.to_seq |> Query.matching expression
          |> Seq.map (fun pane -> `String (Pane.Id.to_string (Pane.id pane)))
          |> List.of_seq
        in
        `Assoc
          [
            ("name", member "name" case);
            ("matches", `List matches);
            ("encoded", codec (Libtmux_json.Expr.encode Model.pane expression));
          ])
  in
  Yojson.Safe.to_channel stdout (`List results);
  print_newline ()
