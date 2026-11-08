open Libtmux

let get = function
  | Ok value -> value
  | Error error ->
      failwith (Format.asprintf "%a" Libtmux_json.Decode_error.pp error)

let () =
  let query = Expr.Text.starts_with Pane.Fields.current_command "nv" in
  let document = get (Libtmux_json.Expr.to_string Model.pane query) in
  print_endline document;
  let decoded = get (Libtmux_json.Expr.of_string Model.pane document) in
  assert (Expr.describe decoded = Expr.describe query);
  let invalid =
    {|{"schema":"libtmux.filter/1","model":"pane","expr":{"node":"compare","field":"pane_width","op":"ge","value":"wide"}}|}
  in
  match Libtmux_json.Expr.of_string Model.pane invalid with
  | Error error -> Printf.printf "invalid operand at %s\n" error.pointer
  | Ok _ -> failwith "string width was accepted"
