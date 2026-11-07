module Kind = struct
  type t = Format_catalog.kind = Text | Timestamp
end

module Context = struct
  type t = Format_catalog.context =
    | Server
    | Connection
    | Session
    | Window
    | Window_link
    | Pane
    | Client
    | Buffer
    | Mouse
    | Command
end

type descriptor = Format_catalog.descriptor = {
  name : string;
  kind : Kind.t;
  contexts : Context.t list;
  versions : string list;
}

type observation =
  | Snapshot of Graph.Snapshot.t
  | Session of Graph.Session.t
  | Window of Graph.Window.t
  | Window_link of Graph.Window_link.t
  | Pane of Graph.Pane.t
  | Client of Graph.Client_observation.t

type scalar = Bool of bool | Int of int | Text of string
type state = Value of scalar | Missing | Unacquired | Unsupported

let catalog ~version =
  if not (List.mem version Format_catalog.versions) then
    Error (Error.Unsupported ("format catalog for tmux " ^ version))
  else
    Ok
      (Format_catalog.entries |> Iarray.to_seq
      |> Seq.filter (fun entry -> List.mem version entry.versions)
      |> Iarray.of_seq)

let describe ~version name =
  Result.map
    (Iarray.find_opt (fun entry -> entry.name = name))
    (catalog ~version)

let fields : type a. a Filter.Field.packed list -> a -> string -> state =
 fun fields value name ->
  match
    List.find_opt (fun (Filter.Field.Pack field) -> field.name = name) fields
  with
  | None -> Unacquired
  | Some (Filter.Field.Pack field) -> (
      match field.kind with
      | Bool -> Value (Bool (field.get value))
      | Int -> Value (Int (field.get value))
      | Text -> Value (Text (field.get value)))

let optional convert = function
  | None -> Missing
  | Some value -> Value (convert value)

let read observation name =
  match observation with
  | Snapshot snapshot ->
      if name = "pid" then
        Value (Int (Graph.Source.server_pid (Graph.Snapshot.source snapshot)))
      else Unacquired
  | Session value -> fields Generated_fields.Session.fields value name
  | Window value -> fields Generated_fields.Window.fields value name
  | Window_link value -> (
      match fields Generated_fields.Window_link.fields value name with
      | Unacquired -> (
          match
            fields Generated_fields.Window.fields
              (Graph.Window_link.window value)
              name
          with
          | Unacquired ->
              fields Generated_fields.Session.fields
                (Graph.Window_link.session value)
                name
          | found -> found)
      | found -> found)
  | Pane value -> (
      if name = "pane_pid" then
        optional (fun value -> Int value) (Graph.Pane.pid value)
      else
        match fields Generated_fields.Pane.fields value name with
        | Unacquired ->
            fields Generated_fields.Window.fields (Graph.Pane.window value) name
        | found -> found)
  | Client value ->
      if name = "client_height" then
        optional
          (fun value -> Int value)
          (Graph.Client_observation.height value)
      else if name = "client_session" then
        optional
          (fun value -> Text (Graph.Session.name value))
          (Graph.Client_observation.session value)
      else fields Generated_fields.Client_observation.fields value name

let lookup ~version observation name =
  Result.map
    (function None -> Unsupported | Some _ -> read observation name)
    (describe ~version name)
