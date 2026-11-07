module Endpoint = Endpoint
module Error = Error
module Generation = Graph.Generation
module Source = Graph.Source
module Client_name = Graph.Client_name

module type ID = sig
  type t

  val of_string : string -> (t, Error.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Field = Filter.Field
module Relation = Filter.Relation

module Session = struct
  include Graph.Session
  module Fields = Generated_fields.Session

  module Relations = struct
    let window_links =
      Relation.Many.{ name = "window_links"; get = window_links }

    let windows = Relation.Many.{ name = "windows"; get = windows }
  end
end

module Window = struct
  include Graph.Window
  module Fields = Generated_fields.Window

  module Relations = struct
    let panes = Relation.Many.{ name = "panes"; get = panes }
    let links = Relation.Many.{ name = "links"; get = links }
  end
end

module Window_link = struct
  include Graph.Window_link
  module Fields = Generated_fields.Window_link

  module Relations = struct
    let session = Relation.One.{ name = "session"; get = session }
    let window = Relation.One.{ name = "window"; get = window }
  end
end

module Pane = struct
  include Graph.Pane
  module Fields = Generated_fields.Pane

  module Relations = struct
    let window = Relation.One.{ name = "window"; get = window }
  end
end

module Client_observation = struct
  include Graph.Client_observation
  module Fields = Generated_fields.Client_observation

  module Relations = struct
    let session = Relation.Optional.{ name = "session"; get = session }
  end
end

module Snapshot = Graph.Snapshot
module Expr = Filter.Expr
module Plan = Planner

module Model = struct
  type 'a t = { name : string; fields : 'a Field.packed list }

  let session = { name = "session"; fields = Generated_fields.Session.fields }
  let window = { name = "window"; fields = Generated_fields.Window.fields }

  let window_link =
    { name = "window_link"; fields = Generated_fields.Window_link.fields }

  let pane = { name = "pane"; fields = Generated_fields.Pane.fields }

  let client =
    { name = "client"; fields = Generated_fields.Client_observation.fields }

  let name model = model.name
  let fields model = model.fields

  let find_field model name =
    List.find_opt
      (fun (Field.Pack field) -> String.equal (Field.name field) name)
      model.fields
end

module Cardinality = struct
  type error = No_match | Multiple_matches of { at_least : int }

  let pp_error formatter = function
    | No_match -> Format.pp_print_string formatter "no match"
    | Multiple_matches { at_least } ->
        Format.fprintf formatter "at least %d matches" at_least
end

module Query = struct
  let matching expression =
    let predicate = Expr.compile expression in
    fun values -> Seq.filter predicate values

  let one_or_none values =
    match Seq.uncons values with
    | None -> Ok None
    | Some (value, rest) -> (
        match Seq.uncons rest with
        | None -> Ok (Some value)
        | Some _ -> Error (Cardinality.Multiple_matches { at_least = 2 }))

  let exactly_one values =
    match one_or_none values with
    | Ok None -> Error Cardinality.No_match
    | Ok (Some value) -> Ok value
    | Error error -> Error error
end

module Captured_text = Commands.Captured_text
module Key = Commands.Key
module Spawn = Commands.Spawn
module Geometry = Commands.Geometry
module Layout = Commands.Layout
module Created = Commands.Created
module Environment = Commands.Environment
module Options = Options
module Hook = Commands.Hook
module Command = Commands.Command
module Operations = Commands.Operations
module Formats = Formats
module Output = Output
