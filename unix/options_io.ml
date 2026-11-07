open Libtmux
open Runtime_io
module P = Libtmux__Protocol
module Names = Set.Make (String)

(* args_escape already encodes all controls. The 3.4 print layer adds only
   the extra dollar escape to these ASCII escape sequences and valid UTF-8. *)
let print_layer dialect text =
  match dialect with
  | P.Metadata.Raw -> text
  | Visual ->
      let buffer = Buffer.create (String.length text) in
      let variable = function
        | 'a' .. 'z' | 'A' .. 'Z' | '_' | '{' -> true
        | _ -> false
      in
      String.iteri
        (fun i c ->
          if c = '$' && i + 1 < String.length text && variable text.[i + 1] then (
            if i = 0 || text.[i - 1] <> '\\' then
              P.malformed "missing visual dollar escape";
            Buffer.truncate buffer (Buffer.length buffer - 1));
          Buffer.add_char buffer c)
        text;
      Buffer.contents buffer

let text_value text =
  let length = String.length text in
  if length = 0 then P.malformed "missing quoted option value";
  let start, stop =
    if text.[0] = '\'' || text.[0] = '"' then (
      if length < 2 || text.[length - 1] <> text.[0] then
        P.malformed "unterminated quoted option value";
      (1, length - 1))
    else (0, length)
  in
  let buffer = Buffer.create 64 in
  let append c =
    if c = '\000' then P.malformed "NUL in option value";
    if Buffer.length buffer = 65_536 then P.limit "option value exceeds 64 KiB";
    Buffer.add_char buffer c
  in
  let octal c = c >= '0' && c <= '7' in
  let rec read i =
    if i < stop then
      if text.[i] <> '\\' then (
        if
          (start = 1 && text.[i] = text.[0])
          || (start = 0 && String.contains " \"'" text.[i])
        then P.malformed "unescaped option quote or separator";
        append text.[i];
        read (i + 1))
      else (
        if i + 1 = stop then P.malformed "truncated option escape";
        let c = text.[i + 1] in
        if octal c then (
          if i + 3 >= stop || not (octal text.[i + 2] && octal text.[i + 3])
          then P.malformed "invalid option octal escape";
          let digit j = Char.code text.[i + j] - Char.code '0' in
          let value = (64 * digit 1) + (8 * digit 2) + digit 3 in
          if value > 255 then P.malformed "option escape exceeds byte range";
          append (Char.chr value);
          read (i + 4))
        else
          let value =
            match c with
            | 'n' -> '\n'
            | 'r' -> '\r'
            | 'b' -> '\b'
            | 'a' -> '\007'
            | 'v' -> '\011'
            | 't' -> '\t'
            | 'f' -> '\012'
            | 's' -> ' '
            | c when String.contains "\\\"'~ #;${}%" c -> c
            | _ -> P.malformed "invalid option escape"
          in
          append value;
          read (i + 2))
  in
  read start;
  Buffer.contents buffer

let scalar kind text =
  if kind <> Options.Kind.Text && String.length text > 65_536 then
    P.limit "option value exceeds 64 KiB";
  match kind with
  | Options.Kind.Text -> Options.Text (text_value text)
  | Number -> (
      match Int64.of_string_opt text with
      | Some value when Int64.to_string value = text -> Options.Integer value
      | _ -> P.malformed "invalid numeric option")
  | Flag -> (
      match text with
      | "on" -> Options.Bool true
      | "off" -> Bool false
      | _ -> P.malformed "invalid flag option")
  | Choice -> Options.Choice text
  | Key -> Options.Key text
  | Colour -> Options.Colour text
  | Commands -> Options.Commands text

let decode ~version ~dialect body =
  let length = String.length body in
  let finish descriptor inherited values =
    let value =
      if descriptor.Options.array then
        Options.Array (Iarray.of_list (List.rev values))
      else
        match values with
        | [ (-1, value) ] -> Options.Scalar value
        | _ -> P.malformed "invalid scalar option rows"
    in
    Options.{ descriptor; value; inherited }
  in
  let name text =
    let inherited = String.ends_with ~suffix:"*" text in
    let text = if inherited then String.drop_last 1 text else text in
    match String.index_opt text '[' with
    | None -> (text, -1, inherited)
    | Some at ->
        if not (String.ends_with ~suffix:"]" text) then
          P.malformed "invalid option index";
        let value = String.sub text (at + 1) (String.length text - at - 2) in
        let index =
          match int_of_string_opt value with
          | Some n when n >= 0 && n <= 2_147_483_647 && Int.to_string n = value
            ->
              n
          | _ -> P.malformed "invalid option index"
        in
        (String.sub text 0 at, index, inherited)
  in
  let rec rows pos count seen pending entries =
    if pos = length then
      let entries =
        match pending with
        | None -> entries
        | Some (descriptor, inherited, values) ->
            finish descriptor inherited values :: entries
      in
      Iarray.of_list (List.rev entries)
    else (
      if count = 10_000 then P.limit "option table exceeds 10000 rows";
      let ending =
        match String.index_from_opt body pos '\n' with
        | Some n -> n
        | None -> P.malformed "truncated option row"
      in
      let line = String.sub body pos (ending - pos) in
      let raw_name, text =
        match String.index_opt line ' ' with
        | None -> (line, None)
        | Some n -> (String.sub line 0 n, Some (String.drop_first (n + 1) line))
      in
      let name, index, inherited = name raw_name in
      let descriptor = get (Options.describe ~version name) in
      let seen, values, entries =
        match pending with
        | Some (previous, flag, values) when previous.name = name ->
            if
              (not descriptor.array) || flag <> inherited || index < 0
              ||
              match values with
              | [] -> true
              | (last, _) :: _ -> index <= last
            then P.malformed "conflicting option rows";
            (seen, values, entries)
        | other ->
            if Names.mem name seen then P.malformed "duplicate option name";
            let entries =
              match other with
              | None -> entries
              | Some (descriptor, inherited, values) ->
                  finish descriptor inherited values :: entries
            in
            (Names.add name seen, [], entries)
      in
      let values =
        match text with
        | None when descriptor.array && index = -1 -> []
        | Some text when descriptor.array = (index >= 0) ->
            if String.length text > 262_144 then
              P.limit "encoded option exceeds 256 KiB";
            (index, scalar descriptor.kind (print_layer dialect text)) :: values
        | _ -> P.malformed "option kind and row shape disagree"
      in
      rows (ending + 1) (count + 1) seen
        (Some (descriptor, inherited, values))
        entries)
  in
  protocol
    (P.protect (fun () ->
         if String.contains body '\000' then P.malformed "NUL in option table";
         rows 0 0 Names.empty None []))

let capture ?(hooks = false) c scope include_inherited arguments =
  let started_at_ns = Linux.monotonic_ns () in
  Read_process.run c
    (if hooks then "show-hooks" else "show-options")
    arguments
    (fun body ->
      let entries =
        decode ~version:c.Connection.version ~dialect:c.dialect body
      in
      if
        Iarray.exists
          (fun entry -> entry.Options.descriptor.hook <> hooks)
          entries
      then fail (Error.Malformed_data "unexpected kind in option table");
      Options.
        {
          source = c.source;
          scope;
          include_inherited;
          entries;
          started_at_ns;
          finished_at_ns = Linux.monotonic_ns ();
        })

let read c name arguments =
  try
    Read_process.run c "show-options" arguments (fun body ->
        let entries =
          decode ~version:c.Connection.version ~dialect:c.dialect body
        in
        match Iarray.to_list entries with
        | [] -> None
        | [ entry ] when entry.descriptor.name = name -> Some entry.value
        | _ -> fail (Error.Malformed_data "unexpected named option result"))
  with
  | Failure (Error.Command_failed { message; _ })
  when String.starts_with ~prefix:"@" name
       && message = "invalid option: " ^ name ^ "\n"
  ->
    None
