module Decode_error = struct
  type category =
    | Syntax
    | Limit
    | Unknown
    | Wrong_type
    | Out_of_range
    | Unsupported

  type t = { pointer : string; category : category; message : string }

  let pp formatter error =
    Format.fprintf formatter "%s: %s"
      (if error.pointer = "" then "/" else error.pointer)
      error.message
end

exception Decode of Decode_error.t

let fail pointer category message =
  raise (Decode { pointer; category; message })

let protect f = try Ok (f ()) with Decode error -> Error error
let max_bytes = 65_536

let member_path path name =
  path ^ "/"
  ^ String.replace_all ~sub:"/" ~by:"~1"
      (String.replace_all ~sub:"~" ~by:"~0" name)

let string_cost text =
  String.fold_left
    (fun n char ->
      n
      +
      match char with
      | '"' | '\\' | '\b' | '\012' | '\n' | '\r' | '\t' -> 2
      | c when Char.code c < 32 -> 6
      | _ -> 1)
    2 text

let check_utf8 path text =
  if not (String.is_valid_utf_8 text) then
    fail path Decode_error.Syntax "invalid UTF-8 text"

let validate_tree document =
  let bytes = ref 0 in
  let charge n =
    bytes := !bytes + n;
    if !bytes > max_bytes then
      fail "" Decode_error.Limit "document exceeds 64 KiB"
  in
  let rec walk path depth : Yojson.Safe.t -> unit =
   fun value ->
    if depth > 32 then
      fail path Decode_error.Limit "JSON nesting exceeds 32 levels";
    match value with
    | `Assoc pairs ->
        charge (2 + max 0 (List.length pairs - 1));
        let names = Hashtbl.create 8 in
        List.iter
          (fun (name, value) ->
            let child = member_path path name in
            if Hashtbl.mem names name then
              fail child Decode_error.Syntax "duplicate property";
            Hashtbl.add names name ();
            check_utf8 child name;
            charge (string_cost name + 1);
            walk child (depth + 1) value)
          pairs
    | `List values ->
        charge (2 + max 0 (List.length values - 1));
        List.iteri
          (fun i value -> walk (path ^ "/" ^ Int.to_string i) (depth + 1) value)
          values
    | `String text ->
        check_utf8 path text;
        charge (string_cost text)
    | `Int number -> charge (String.length (Int.to_string number))
    | `Intlit number -> charge (String.length number)
    | `Float _ -> charge 24
    | `Bool value -> charge (if value then 4 else 5)
    | `Null -> charge 4
  in
  walk "" 0 document

let object_ path allowed = function
  | `Assoc pairs ->
      List.iter
        (fun (name, _) ->
          if not (List.mem name allowed) then
            fail (member_path path name) Decode_error.Unknown "unknown property")
        pairs;
      pairs
  | _ -> fail path Decode_error.Wrong_type "expected an object"

let required path properties name =
  match List.assoc_opt name properties with
  | Some value -> value
  | None ->
      fail (member_path path name) Decode_error.Wrong_type
        "required property is absent"

let text path = function
  | `String value -> value
  | _ -> fail path Decode_error.Wrong_type "expected a string"

let integer path = function
  | `Int value when value >= -2_147_483_648 && value <= 2_147_483_647 -> value
  | `Int _ | `Intlit _ ->
      fail path Decode_error.Out_of_range "expected a signed 32-bit integer"
  | _ -> fail path Decode_error.Wrong_type "expected an integer"

let boolean path = function
  | `Bool value -> value
  | _ -> fail path Decode_error.Wrong_type "expected a Boolean"

let parse text =
  if String.length text > max_bytes then
    fail "" Decode_error.Limit "document exceeds 64 KiB";
  check_utf8 "" text;
  let depth = ref 0 and quoted = ref false and escaped = ref false in
  String.iter
    (fun char ->
      if !quoted then (
        if Char.code char < 32 then
          fail "" Decode_error.Syntax "unescaped control byte in JSON string";
        if !escaped then escaped := false
        else if char = '\\' then escaped := true
        else if char = '"' then quoted := false)
      else
        match char with
        | '"' -> quoted := true
        | '{' | '[' ->
            incr depth;
            if !depth > 32 then
              fail "" Decode_error.Limit "JSON nesting exceeds 32 levels"
        | '}' | ']' -> decr depth
        | '/' | '(' | ')' | '<' | '>' ->
            fail "" Decode_error.Syntax "non-JSON syntax"
        | _ -> ())
    text;
  try Yojson.Safe.from_string text
  with Yojson.Json_error _ -> fail "" Decode_error.Syntax "invalid JSON"
