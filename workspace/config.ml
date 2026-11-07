open Libtmux

type error = { path : string; message : string }

exception Invalid of error

let pp_error formatter error =
  Format.fprintf formatter "%s: %s" error.path error.message

let fail path message = raise (Invalid { path; message })

type setting = { name : string; index : int option; value : Options.scalar }

type pane = {
  spawn : Spawn.t;
  options : setting list;
  startup : string list;
  direction : Geometry.direction;
  size : Geometry.size option;
}

type window = {
  name : string;
  cwd : string option;
  environment : (string * string) list;
  options : setting list;
  panes : pane list;
  layout : Layout.t option;
}

type t = {
  session : string;
  windows : window Iarray.t;
  environment : (string * string) list;
  options : setting list;
  width : int;
  height : int;
}

let pane ?(spawn = Spawn.default) ?(options = []) ?(startup = [])
    ?(direction = Geometry.Below) ?size () =
  { spawn; options; startup; direction; size }

let window ?cwd ?(environment = []) ?(options = []) ?layout ~name panes =
  { name; cwd; environment; options; panes; layout }

let identifier name =
  String.length name > 0
  && (match name.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
       name

let unique path key values =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun value ->
      let name = key value in
      if Hashtbl.mem seen name then fail path "duplicate entry";
      Hashtbl.add seen name ())
    values

let make ?cwd ?(environment = []) ?(options = []) ?(variables = [])
    ?(width = 120) ?(height = 40) ~directory ~session windows =
  try
    let bytes = ref 0 in
    let text path ?(empty = true) value =
      bytes := !bytes + String.length value;
      if !bytes > 1_048_576 then fail path "workspace text exceeds 1 MiB";
      if String.length value > 65_536 then fail path "text exceeds 64 KiB";
      if (not empty) && value = "" then fail path "empty text";
      if String.contains value '\000' then fail path "NUL is unsupported"
    in
    let name path value =
      text path ~empty:false value;
      if String.length value > 256 then fail path "name exceeds 256 bytes";
      if
        String.exists
          (function ':' | '.' | '\r' | '\n' -> true | _ -> false)
          value
      then fail path "name contains a tmux target separator or newline"
    in
    let environment_ path values =
      if List.compare_length_with values 256 > 0 then
        fail path "too many variables";
      unique path fst values;
      List.iter
        (fun (key, value) ->
          text path key;
          if not (identifier key) then
            fail path "expected an ASCII environment name";
          text path value)
        values
    in
    environment_ "/variables" variables;
    let expanded = Hashtbl.create 8 in
    let rec expand path stack value =
      let buffer = Buffer.create (String.length value) in
      let add part =
        if String.length part > 65_536 - Buffer.length buffer then
          fail path "expanded directory exceeds 64 KiB";
        Buffer.add_string buffer part
      in
      let rec scan offset =
        if offset < String.length value then
          if
            offset + 1 < String.length value
            && value.[offset] = '$'
            && value.[offset + 1] = '{'
          then (
            let ending =
              match String.index_from_opt value (offset + 2) '}' with
              | Some ending -> ending
              | None -> fail path "unterminated directory variable"
            in
            let variable =
              String.sub value (offset + 2) (ending - offset - 2)
            in
            add (resolve path stack variable);
            scan (ending + 1))
          else (
            add (String.make 1 value.[offset]);
            scan (offset + 1))
      in
      scan 0;
      Buffer.contents buffer
    and resolve path stack variable =
      if List.mem variable stack then fail path "directory variable cycle";
      match Hashtbl.find_opt expanded variable with
      | Some value -> value
      | None ->
          let value =
            match List.assoc_opt variable variables with
            | Some value -> expand path (variable :: stack) value
            | None -> fail path "unknown directory variable"
          in
          Hashtbl.add expanded variable value;
          value
    in
    List.iter (fun (key, _) -> ignore (resolve "/variables" [] key)) variables;
    let absolute path ~parent value =
      text path ~empty:false value;
      let value = expand path [] value in
      let value =
        if Filename.is_relative value then Filename.concat parent value
        else value
      in
      (* Keep symlink-sensitive [..] segments for the operating system. *)
      if Filename.is_relative value then fail path "directory must be absolute";
      text path ~empty:false value;
      value
    in
    text "/directory" ~empty:false directory;
    if Filename.is_relative directory then
      fail "/directory" "document directory must be absolute";
    let root =
      match cwd with
      | None -> directory
      | Some value -> absolute "/cwd" ~parent:directory value
    in
    let merge parent local =
      List.filter (fun (key, _) -> not (List.mem_assoc key local)) parent
      @ local
    in
    let settings path values =
      if List.compare_length_with values 256 > 0 then
        fail path "too many options";
      unique path (fun (s : setting) -> (s.name, s.index)) values;
      List.iter
        (fun (setting : setting) ->
          text path ~empty:false setting.name;
          Option.iter
            (fun index ->
              if index < 0 || index > 65_535 then
                fail path "invalid array index")
            setting.index;
          match setting.value with
          | Options.Text value
          | Choice value
          | Key value
          | Colour value
          | Commands value ->
              text path value
          | Integer _ | Bool _ -> ())
        values
    in
    name "/session" session;
    if width < 1 || width > 10_000 || height < 1 || height > 10_000 then
      fail "/size" "dimensions must be 1..10000";
    if windows = [] || List.compare_length_with windows 64 > 0 then
      fail "/windows" "expected 1..64 windows";
    unique "/windows" (fun w -> w.name) windows;
    environment_ "/environment" environment;
    settings "/options" options;
    let pane_count = ref 0 in
    let windows =
      List.mapi
        (fun wi window ->
          let path = "/windows/" ^ Int.to_string wi in
          name (path ^ "/name") window.name;
          environment_ (path ^ "/environment") window.environment;
          settings (path ^ "/options") window.options;
          Option.iter
            (function
              | Layout.Custom value ->
                  text (path ^ "/layout") ~empty:false value
              | _ -> ())
            window.layout;
          if window.panes = [] then
            fail (path ^ "/panes") "expected at least one pane";
          let cwd =
            match window.cwd with
            | None -> root
            | Some value -> absolute (path ^ "/cwd") ~parent:directory value
          in
          let inherited = merge environment window.environment in
          let panes =
            List.mapi
              (fun pi pane ->
                incr pane_count;
                if !pane_count > 256 then
                  fail "/windows" "workspace exceeds 256 panes";
                let path = path ^ "/panes/" ^ Int.to_string pi in
                let environment = merge inherited pane.spawn.environment in
                environment_ (path ^ "/environment") environment;
                settings (path ^ "/options") pane.options;
                let command = pane.spawn.command in
                (match command with
                | Spawn.Default -> ()
                | Exec { program; args } ->
                    text (path ^ "/exec/0") ~empty:false program;
                    if program.[0] = '-' then
                      fail (path ^ "/exec/0")
                        "executable must not start with '-'";
                    if List.compare_length_with args 256 > 0 then
                      fail path "argv exceeds 257 entries";
                    List.iter (text (path ^ "/exec")) args
                | Shell code -> text (path ^ "/shell") ~empty:false code);
                if List.compare_length_with pane.startup 256 > 0 then
                  fail path "too many startup commands";
                List.iter
                  (fun command ->
                    text (path ^ "/startup") ~empty:false command;
                    if
                      String.contains command '\n'
                      || String.contains command '\r'
                    then fail path "startup commands must be single lines")
                  pane.startup;
                Option.iter
                  (function
                    | Geometry.Cells value when value > 0 && value <= 10_000 ->
                        ()
                    | Percent value when value > 0 && value < 100 -> ()
                    | _ -> fail (path ^ "/size") "invalid split size")
                  pane.size;
                let cwd =
                  match pane.spawn.cwd with
                  | None -> cwd
                  | Some value ->
                      absolute (path ^ "/cwd") ~parent:directory value
                in
                { pane with spawn = { command; cwd = Some cwd; environment } })
              window.panes
          in
          { window with cwd = Some cwd; panes })
        windows
      |> Iarray.of_list
    in
    Ok { session; windows; environment; options; width; height }
  with Invalid error -> Error error

let session t = t.session
let windows t = t.windows
let environment t = t.environment
let options t = t.options
let dimensions t = (t.width, t.height)
