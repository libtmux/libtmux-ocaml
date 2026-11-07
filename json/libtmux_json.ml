open Libtmux
open Document
module Decode_error = Document.Decode_error

module Error = struct
  let encode value = Workspace_output.error (ref 0) value
end

let shared_fields =
  [
    "pane_id";
    "pane_current_command";
    "pane_index";
    "pane_active";
    "pane_title";
    "pane_current_path";
    "pane_width";
    "pane_height";
    "pane_left";
    "pane_top";
  ]

let require_model model =
  if Model.name model <> "pane" then
    fail "/model" Decode_error.Unsupported
      "only the shared pane model is supported"

let require_field path model name =
  if not (List.mem name shared_fields) then
    fail path Decode_error.Unsupported
      "field is outside the shared pane registry";
  match Model.find_field model name with
  | Some field -> field
  | None -> fail path Decode_error.Unknown "unknown canonical field"

let comparison : type a v.
    string -> (a, v) Field.t -> string -> Yojson.Safe.t -> a Expr.t =
 fun path field operator operand ->
  let value_path = path ^ "/value" in
  let unsupported () =
    fail (path ^ "/op") Decode_error.Unsupported
      "operator is unsupported for this field"
  in
  match Field.kind field with
  | Field.Bool -> (
      let value = boolean value_path operand in
      match operator with
      | "equals" -> Expr.Bool.equal field value
      | "not_equals" -> Expr.not_ (Expr.Bool.equal field value)
      | _ -> unsupported ())
  | Field.Int -> (
      let value = integer value_path operand in
      match operator with
      | "equals" -> Expr.Int.equal field value
      | "not_equals" -> Expr.not_ (Expr.Int.equal field value)
      | "less_than" -> Expr.Int.lt field value
      | "at_most" -> Expr.Int.le field value
      | "greater_than" -> Expr.Int.gt field value
      | "at_least" -> Expr.Int.ge field value
      | _ -> unsupported ())
  | Field.Text -> (
      if operator = "in" then
        match operand with
        | `List values ->
            if List.compare_length_with values 256 > 0 then
              fail value_path Decode_error.Limit
                "membership list exceeds 256 values";
            Expr.Text.is_in field
              (List.mapi
                 (fun i value ->
                   text (value_path ^ "/" ^ Int.to_string i) value)
                 values)
        | _ ->
            fail value_path Decode_error.Wrong_type
              "expected a membership array"
      else if operator = "matches" then unsupported ()
      else
        let value = text value_path operand in
        match operator with
        | "equals" -> Expr.Text.equal field value
        | "not_equals" -> Expr.not_ (Expr.Text.equal field value)
        | "starts_with" -> Expr.Text.starts_with field value
        | "ends_with" -> Expr.Text.ends_with field value
        | "contains" -> Expr.Text.contains field value
        | _ -> unsupported ())

let decode_document model document =
  require_model model;
  validate_tree document;
  let root = object_ "" [ "schema"; "model"; "expr" ] document in
  if text "/schema" (required "" root "schema") <> "libtmux.filter/1" then
    fail "/schema" Decode_error.Unsupported "unsupported filter schema";
  if text "/model" (required "" root "model") <> Model.name model then
    fail "/model" Decode_error.Wrong_type
      "document model does not match the requested witness";
  let nodes = ref 0 in
  let rec decode path value =
    incr nodes;
    if !nodes > 1024 then
      fail path Decode_error.Limit "expression exceeds 1024 nodes";
    let properties =
      match value with
      | `Assoc pairs -> pairs
      | _ -> fail path Decode_error.Wrong_type "expected an expression object"
    in
    let kind = text (path ^ "/node") (required path properties "node") in
    let only names = ignore (object_ path names value) in
    match kind with
    | "and" | "or" ->
        only [ "node"; "operands" ];
        let children =
          match required path properties "operands" with
          | `List values ->
              List.mapi
                (fun i value ->
                  decode (path ^ "/operands/" ^ Int.to_string i) value)
                values
          | _ ->
              fail (path ^ "/operands") Decode_error.Wrong_type
                "expected an array"
        in
        if kind = "and" then Expr.all children else Expr.any children
    | "not" ->
        only [ "node"; "operand" ];
        Expr.not_
          (decode (path ^ "/operand") (required path properties "operand"))
    | "compare" ->
        only [ "node"; "field"; "op"; "value" ];
        let name = text (path ^ "/field") (required path properties "field") in
        let (Field.Pack field) = require_field (path ^ "/field") model name in
        comparison path field
          (text (path ^ "/op") (required path properties "op"))
          (required path properties "value")
    | "to_many" | "to_one" ->
        fail path Decode_error.Unsupported
          "relationship wire compatibility is not qualified"
    | _ -> fail (path ^ "/node") Decode_error.Unknown "unknown expression node"
  in
  decode "/expr" (required "" root "expr")

module Expr = struct
  let decode model document = protect (fun () -> decode_document model document)

  let of_string model document =
    protect (fun () -> decode_document model (parse document))

  let encode model expression =
    protect (fun () ->
        require_model model;
        let bytes = ref 0 and nodes = ref 0 in
        let charge n =
          bytes := !bytes + n;
          if !bytes > max_bytes then
            fail "" Decode_error.Limit "document exceeds 64 KiB"
        in
        let string path value =
          check_utf8 path value;
          charge (string_cost value);
          `String value
        in
        let object_ pairs =
          charge (2 + max 0 (List.length pairs - 1));
          List.iter (fun (key, _) -> charge (string_cost key + 1)) pairs;
          `Assoc pairs
        in
        let array values =
          charge (2 + max 0 (List.length values - 1));
          `List values
        in
        let int value =
          ignore (integer "/expr/value" (`Int value));
          charge (String.length (Int.to_string value));
          `Int value
        in
        let operand : type a.
            a Libtmux.Expr.comparison -> string * Yojson.Safe.t = function
          | Bool_equal value ->
              charge (if value then 4 else 5);
              ("equals", `Bool value)
          | Int_equal value -> ("equals", int value)
          | Int_lt value -> ("less_than", int value)
          | Int_le value -> ("at_most", int value)
          | Int_gt value -> ("greater_than", int value)
          | Int_ge value -> ("at_least", int value)
          | Int_in _ ->
              fail "/expr" Decode_error.Unsupported
                "Java numeric membership is unsupported"
          | Text_equal value -> ("equals", string "/expr/value" value)
          | Text_starts_with value -> ("starts_with", string "/expr/value" value)
          | Text_ends_with value -> ("ends_with", string "/expr/value" value)
          | Text_contains value -> ("contains", string "/expr/value" value)
          | Text_in values ->
              if List.compare_length_with values 256 > 0 then
                fail "/expr/value" Decode_error.Limit
                  "membership list exceeds 256 values";
              ("in", array (List.map (string "/expr/value") values))
        in
        let rec node depth expression =
          incr nodes;
          if !nodes > 1024 || depth > 32 then
            fail "/expr" Decode_error.Limit
              "expression exceeds node or depth limit";
          let kind name = ("node", string "/expr/node" name) in
          match Libtmux.Expr.view expression with
          | All children ->
              object_
                [
                  kind "and";
                  ("operands", array (List.map (node (depth + 2)) children));
                ]
          | Any children ->
              object_
                [
                  kind "or";
                  ("operands", array (List.map (node (depth + 2)) children));
                ]
          | Not child ->
              object_ [ kind "not"; ("operand", node (depth + 1) child) ]
          | Compare (field, op) ->
              let name = Field.name field in
              ignore (require_field "/expr/field" model name);
              let operator, value = operand op in
              object_
                [
                  kind "compare";
                  ("field", string "/expr/field" name);
                  ("op", string "/expr/op" operator);
                  ("value", value);
                ]
          | Related_any _ | Related_all _ | Related_none _ | Related_one _
          | Related_optional _ | Absent _ ->
              fail "/expr" Decode_error.Unsupported
                "relationship wire compatibility is not qualified"
        in
        let document =
          object_
            [
              ("schema", string "/schema" "libtmux.filter/1");
              ("model", string "/model" (Model.name model));
              ("expr", node 1 expression);
            ]
        in
        validate_tree document;
        document)

  let to_string model expression =
    Result.map Yojson.Safe.to_string (encode model expression)
end

module Workspace = struct
  include Workspace_json

  let encode_plan = Workspace_output.plan
  let encode_receipt = Workspace_output.receipt
end
