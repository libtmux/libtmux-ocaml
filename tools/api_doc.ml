(* Convert parsed odoc comments; keep native comments in the export as well. *)
open Odoc_parser.Loc

let rec inline elements =
  elements
  |> List.map (fun item ->
      match item.value with
      | `Space _ -> " "
      | `Word text -> text
      | `Code_span text -> "`" ^ text ^ "`"
      | `Raw_markup (_, text) -> text
      | `Styled (style, content) ->
          let mark = if style = `Bold then "**" else "*" in
          mark ^ inline content ^ mark
      | `Reference (_, target, []) -> "`" ^ target.value ^ "`"
      | `Reference (_, _, content) -> inline content
      | `Link (url, content) ->
          "["
          ^ (if content = [] then url else inline content)
          ^ "](" ^ url ^ ")"
      | `Math_span text -> "$" ^ text ^ "$")
  |> String.concat ""

let rec blocks items =
  items |> List.map (fun item -> block item.value) |> String.concat "\n\n"

and block : Odoc_parser.Ast.nestable_block_element -> string = function
  | `Paragraph content -> inline content
  | `Code_block code ->
      let language =
        match code.meta with
        | None -> "ocaml"
        | Some meta -> meta.language.value
      in
      "```" ^ language ^ "\n" ^ String.trim code.content.value ^ "\n```"
  | `Verbatim text -> "```text\n" ^ String.trim text ^ "\n```"
  | `Modules names ->
      names
      |> List.map (fun name -> "`" ^ name.value ^ "`")
      |> String.concat ", "
  | `List (kind, _, entries) ->
      entries
      |> List.mapi (fun i entry ->
          (if kind = `Ordered then string_of_int (i + 1) ^ ". " else "- ")
          ^ blocks entry)
      |> String.concat "\n"
  | `Table (grid, _) ->
      let rows, _ = grid in
      rows
      |> List.map (fun row ->
          row
          |> List.map (fun (items, _) -> blocks items)
          |> String.concat " | ")
      |> String.concat "\n"
  | `Math_block text -> "$$\n" ^ text ^ "\n$$"
  | `Media (_, _, caption, _) -> caption

let decode text =
  let parsed = Odoc_parser.parse_comment ~location:Lexing.dummy_pos ~text in
  let warnings = Odoc_parser.warnings parsed in
  if warnings <> [] then
    failwith
      (String.concat "\n" (List.map Odoc_parser.Warning.to_string warnings));
  let paragraphs = ref [] and metadata = ref [] in
  Odoc_parser.ast parsed
  |> List.iter (fun item ->
      match item.value with
      | #Odoc_parser.Ast.nestable_block_element as value ->
          paragraphs := block value :: !paragraphs
      | `Heading (level, _, content) ->
          paragraphs :=
            (String.make (min 6 (level + 1)) '#' ^ " " ^ inline content)
            :: !paragraphs
      | `Tag (`Since version) ->
          metadata := ("since", `String version) :: !metadata
      | `Tag (`Deprecated content) ->
          metadata := ("deprecated", `String (blocks content)) :: !metadata
      | `Tag (`Param (name, content)) ->
          paragraphs := ("**" ^ name ^ ":** " ^ blocks content) :: !paragraphs
      | `Tag (`Return content) ->
          paragraphs := ("**Returns:** " ^ blocks content) :: !paragraphs
      | `Tag (`Raise (name, content)) ->
          paragraphs :=
            ("**Raises `" ^ name ^ "`:** " ^ blocks content) :: !paragraphs
      | `Tag (`See (_, target, content)) ->
          paragraphs := (target ^ " " ^ blocks content) :: !paragraphs
      | `Tag (`Before (version, content)) ->
          paragraphs :=
            ("Before " ^ version ^ ": " ^ blocks content) :: !paragraphs
      | `Tag (`Version version) ->
          paragraphs := ("Version " ^ version) :: !paragraphs
      | `Tag (`Author _) -> ()
      | `Tag #Odoc_parser.Ast.internal_tag -> ());
  match List.rev !paragraphs with
  | [] -> `Assoc (("summary", `String "") :: !metadata)
  | summary :: rest ->
      `Assoc
        (("summary", `String summary)
         ::
         (if rest = [] then []
          else [ ("body", `String (String.concat "\n\n" rest)) ])
        @ !metadata)
