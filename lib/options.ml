module Kind = Option_catalog.Kind

type descriptor = Option_catalog.descriptor = {
  name : string;
  kind : Kind.t;
  array : bool;
  hook : bool;
  scopes : [ `Server | `Session | `Window | `Pane ] list;
  versions : string list;
}

type scope =
  | Server
  | Global_sessions
  | Global_windows
  | Session of Graph.Session.target
  | Window of Graph.Window.target
  | Pane of Graph.Pane.target

type scalar =
  | Text of string
  | Integer of int64
  | Bool of bool
  | Choice of string
  | Key of string
  | Colour of string
  | Commands of string

type value = Scalar of scalar | Array of (int * scalar) Iarray.t
type entry = { descriptor : descriptor; value : value; inherited : bool }

type t = {
  source : Graph.Source.t;
  scope : scope;
  include_inherited : bool;
  entries : entry Iarray.t;
  started_at_ns : int64;
  finished_at_ns : int64;
}

let known_version version = List.mem version Option_catalog.versions

let catalog ~version =
  if not (known_version version) then
    Error (Error.Unsupported ("option catalog for tmux " ^ version))
  else
    Ok
      (Option_catalog.entries |> Iarray.to_seq
      |> Seq.filter (fun entry -> List.mem version entry.versions)
      |> Iarray.of_seq)

let user_name name =
  String.length name > 1
  && name.[0] = '@'
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' | '@' -> true
         | _ -> false)
       (String.drop_first 1 name)

let describe ~version name =
  if user_name name then
    Ok
      {
        name;
        kind = Text;
        array = false;
        hook = false;
        scopes = [ `Server; `Session; `Window; `Pane ];
        versions = [];
      }
  else if String.starts_with ~prefix:"@" name then
    Error
      (Error.Invalid_input
         "user option name requires ASCII letters, digits, _, -, ., or @")
  else if not (known_version version) then
    Error (Error.Unsupported ("option catalog for tmux " ^ version))
  else
    match
      Iarray.find_opt
        (fun entry -> entry.name = name && List.mem version entry.versions)
        Option_catalog.entries
    with
    | Some descriptor -> Ok descriptor
    | None ->
        Error
          (Error.Unsupported ("unknown option on tmux " ^ version ^ ": " ^ name))

let scope_kind = function
  | Server -> `Server
  | Global_sessions | Session _ -> `Session
  | Global_windows | Window _ -> `Window
  | Pane _ -> `Pane

let lookup table name =
  Iarray.find_opt (fun entry -> entry.descriptor.name = name) table.entries
