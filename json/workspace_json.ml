open Libtmux
open Document
module C = Libtmux_workspace.Config

let decode_document ~directory document =
  validate_tree document;
  let list path = function
    | `List values -> values
    | _ -> fail path Decode_error.Wrong_type "expected an array"
  in
  let optional path properties name decode =
    Option.map (decode (member_path path name)) (List.assoc_opt name properties)
  in
  let entries path = function
    | `Assoc values ->
        List.map
          (fun (key, value) -> (key, text (member_path path key) value))
          values
    | _ -> fail path Decode_error.Wrong_type "expected a string-valued object"
  in
  let default value = function None -> value | Some value -> value in
  let environment path properties =
    optional path properties "environment" entries |> default []
  in
  let int64 path = function
    | `Int value -> Int64.of_int value
    | `Intlit value -> (
        match Int64.of_string_opt value with
        | Some value -> value
        | None ->
            fail path Decode_error.Out_of_range
              "integer exceeds signed 64-bit range")
    | _ -> fail path Decode_error.Wrong_type "expected an integer"
  in
  let settings path properties =
    match List.assoc_opt "options" properties with
    | None -> []
    | Some value ->
        list (path ^ "/options") value
        |> List.mapi (fun i value ->
            let path = path ^ "/options/" ^ Int.to_string i in
            let properties =
              object_ path [ "name"; "kind"; "value"; "index" ] value
            in
            let name =
              text (path ^ "/name") (required path properties "name")
            in
            let kind =
              text (path ^ "/kind") (required path properties "kind")
            in
            let operand = required path properties "value" in
            let value =
              match kind with
              | "text" -> Options.Text (text (path ^ "/value") operand)
              | "number" -> Options.Integer (int64 (path ^ "/value") operand)
              | "flag" -> Options.Bool (boolean (path ^ "/value") operand)
              | "choice" -> Options.Choice (text (path ^ "/value") operand)
              | "key" -> Options.Key (text (path ^ "/value") operand)
              | "colour" -> Options.Colour (text (path ^ "/value") operand)
              | "commands" -> Options.Commands (text (path ^ "/value") operand)
              | _ ->
                  fail (path ^ "/kind") Decode_error.Unknown
                    "unknown option scalar kind"
            in
            C.{ name; index = optional path properties "index" integer; value })
  in
  let pane path value =
    let properties =
      object_ path
        [
          "exec";
          "shell";
          "cwd";
          "environment";
          "options";
          "startup";
          "direction";
          "size";
        ]
        value
    in
    let command =
      match
        (List.assoc_opt "exec" properties, List.assoc_opt "shell" properties)
      with
      | None, None -> Spawn.Default
      | Some argv, None -> (
          match
            list (path ^ "/exec") argv
            |> List.mapi (fun i value ->
                text (path ^ "/exec/" ^ Int.to_string i) value)
          with
          | program :: args -> Spawn.Exec { program; args }
          | [] ->
              fail (path ^ "/exec") Decode_error.Wrong_type
                "exec requires at least one argument")
      | None, Some value -> Spawn.Shell (text (path ^ "/shell") value)
      | Some _, Some _ ->
          fail path Decode_error.Wrong_type
            "exec and shell are mutually exclusive"
    in
    let spawn =
      Spawn.make
        ?cwd:(optional path properties "cwd" text)
        ~environment:(environment path properties)
        command
    in
    let startup =
      optional path properties "startup" (fun path value ->
          list path value
          |> List.mapi (fun i value ->
              text (path ^ "/" ^ Int.to_string i) value))
      |> default []
    in
    let direction =
      optional path properties "direction" (fun path value ->
          match text path value with
          | "left" -> Geometry.Left
          | "right" -> Right
          | "above" -> Above
          | "below" -> Below
          | _ -> fail path Decode_error.Unknown "unknown split direction")
    in
    let size =
      optional path properties "size" (fun path value ->
          let properties = object_ path [ "cells"; "percent" ] value in
          match
            ( List.assoc_opt "cells" properties,
              List.assoc_opt "percent" properties )
          with
          | Some value, None -> Geometry.Cells (integer (path ^ "/cells") value)
          | None, Some value ->
              Geometry.Percent (integer (path ^ "/percent") value)
          | _ ->
              fail path Decode_error.Wrong_type
                "size requires exactly one of cells or percent")
    in
    C.pane ~spawn ~options:(settings path properties) ~startup ?direction ?size
      ()
  in
  let window i value =
    let path = "/windows/" ^ Int.to_string i in
    let properties =
      object_ path
        [ "name"; "cwd"; "environment"; "options"; "panes"; "layout" ]
        value
    in
    let layout =
      optional path properties "layout" (fun path value ->
          match text path value with
          | "even-horizontal" -> Layout.Even_horizontal
          | "even-vertical" -> Even_vertical
          | "main-horizontal" -> Main_horizontal
          | "main-vertical" -> Main_vertical
          | "tiled" -> Tiled
          | _ ->
              fail path Decode_error.Unsupported
                "custom layout strings require the native API")
    in
    let panes =
      list (path ^ "/panes") (required path properties "panes")
      |> List.mapi (fun i value ->
          pane (path ^ "/panes/" ^ Int.to_string i) value)
    in
    C.window
      ~name:(text (path ^ "/name") (required path properties "name"))
      ?cwd:(optional path properties "cwd" text)
      ~environment:(environment path properties)
      ~options:(settings path properties) ?layout panes
  in
  let root =
    object_ ""
      [
        "schema";
        "session";
        "cwd";
        "environment";
        "options";
        "variables";
        "width";
        "height";
        "windows";
      ]
      document
  in
  if text "/schema" (required "" root "schema") <> "libtmux.workspace/1" then
    fail "/schema" Decode_error.Unsupported "unsupported workspace schema";
  let windows =
    list "/windows" (required "" root "windows") |> List.mapi window
  in
  match
    C.make ~directory
      ~session:(text "/session" (required "" root "session"))
      ?cwd:(optional "" root "cwd" text)
      ~environment:(environment "" root) ~options:(settings "" root)
      ?variables:(optional "" root "variables" entries)
      ?width:(optional "" root "width" integer)
      ?height:(optional "" root "height" integer)
      windows
  with
  | Ok config -> config
  | Error error -> fail error.path Decode_error.Wrong_type error.message

let decode ~directory document =
  protect (fun () -> decode_document ~directory document)

let of_string ~directory document =
  protect (fun () -> decode_document ~directory (parse document))
