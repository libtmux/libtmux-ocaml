module Make_id (Prefix : sig
  val value : char
end) : sig
  type t

  val of_string : string -> (t, Error.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end = struct
  type t = string

  let of_string value =
    let length = String.length value in
    if length < 2 || value.[0] <> Prefix.value || (length > 2 && value.[1] = '0')
    then Error (Error.Invalid_input "expected a canonical tmux ID")
    else
      let digits = String.sub value 1 (length - 1) in
      if not (String.for_all (fun c -> c >= '0' && c <= '9') digits) then
        Error (Error.Invalid_input "expected a decimal tmux ID")
      else
        match Int64.of_string_opt digits with
        | Some number when number <= 0xffff_ffffL -> Ok value
        | _ -> Error (Error.Invalid_input "tmux ID exceeds uint32")

  let to_string value = value
  let equal = String.equal
  let compare = String.compare
  let pp = Format.pp_print_string
end

module Session_id = Make_id (struct
  let value = '$'
end)

module Window_id = Make_id (struct
  let value = '@'
end)

module Pane_id = Make_id (struct
  let value = '%'
end)

module Token () : sig
  type t

  val of_string : string -> (t, Error.t) result
  val to_string : t -> string
  val equal : t -> t -> bool
end = struct
  type t = string

  let of_string value =
    if
      String.length value = 64
      && String.for_all
           (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
           value
    then Ok value
    else
      Error (Error.Invalid_input "expected 64 lowercase hexadecimal characters")

  let to_string value = value
  let equal = String.equal
end

module Generation = Token ()

module Source = struct
  type t = {
    endpoint : Endpoint.t;
    generation : Generation.t;
    server_pid : int;
  }

  let create ~endpoint ~generation ~server_pid =
    if server_pid <= 0 then
      Error (Error.Invalid_input "server PID must be positive")
    else Ok { endpoint; generation; server_pid }

  let endpoint value = value.endpoint
  let generation value = value.generation
  let server_pid value = value.server_pid

  let equal a b =
    Endpoint.equal a.endpoint b.endpoint
    && Generation.equal a.generation b.generation
    && a.server_pid = b.server_pid
end

module Rows = struct
  type session = { id : Session_id.t; name : string; attached : int }

  type window = {
    id : Window_id.t;
    name : string;
    width : int;
    height : int;
    layout : string;
  }

  type window_link = {
    session_id : Session_id.t;
    window_id : Window_id.t;
    index : int;
    is_current : bool;
  }

  type pane = {
    id : Pane_id.t;
    window_id : Window_id.t;
    index : int;
    active : bool;
    dead : bool;
    title : string;
    current_command : string;
    current_path : string;
    pid : int option;
    width : int;
    height : int;
    left : int;
    top : int;
  }

  type client = {
    name : string;
    session_id : Session_id.t option;
    pid : int;
    width : int;
    height : int option;
    control_mode : bool;
  }
end

module String_map = Map.Make (String)
module Snapshot_id = Token ()

type arena = {
  source : Source.t;
  snapshot_id : Snapshot_id.t;
  started_at_ns : int64;
  finished_at_ns : int64;
  session_rows : Rows.session Iarray.t;
  window_rows : Rows.window Iarray.t;
  link_rows : Rows.window_link Iarray.t;
  pane_rows : Rows.pane Iarray.t;
  client_rows : Rows.client Iarray.t;
  session_index : int String_map.t;
  window_index : int String_map.t;
  pane_index : int String_map.t;
  session_links : int Iarray.t Iarray.t;
  window_links : int Iarray.t Iarray.t;
  window_panes : int Iarray.t Iarray.t;
}

type session = { arena : arena; row : int }
type window = { arena : arena; row : int }
type window_link = { arena : arena; row : int }
type pane = { arena : arena; row : int }
type client = { arena : arena; row : int }

let session_at arena row : session = { arena; row }
let window_at arena row : window = { arena; row }
let link_at arena row : window_link = { arena; row }
let pane_at arena row : pane = { arena; row }
let client_at arena row : client = { arena; row }

let observation_equal a b =
  Source.equal a.source b.source
  && Snapshot_id.equal a.snapshot_id b.snapshot_id

module Target = struct
  type 'id t = { source : Source.t; id : 'id }

  let source value = value.source
  let id value = value.id
end

module Session = struct
  type t = session

  module Id = Session_id

  type target = Id.t Target.t

  module Target = struct
    type t = target

    let source = Target.source
    let id = Target.id

    let of_id ~source:binding identifier : t =
      { source = binding; id = identifier }
  end

  let data (value : t) = Iarray.get value.arena.session_rows value.row
  let id value = (data value).id
  let name value = (data value).name
  let attached value = (data value).attached
  let source (value : t) = value.arena.source
  let target value = Target.of_id ~source:(source value) (id value)

  let same_entity a b =
    Source.equal (source a) (source b) && Id.equal (id a) (id b)

  let same_observation (a : t) (b : t) =
    same_entity a b && observation_equal a.arena b.arena

  let window_links (value : t) =
    Iarray.map (link_at value.arena)
      (Iarray.get value.arena.session_links value.row)

  let windows (value : t) =
    let _, rows =
      Iarray.fold_left
        (fun (seen, rows) index ->
          let link = Iarray.get value.arena.link_rows index in
          let key = Window_id.to_string link.window_id in
          if String_map.mem key seen then (seen, rows)
          else
            ( String_map.add key () seen,
              String_map.find key value.arena.window_index :: rows ))
        (String_map.empty, [])
        (Iarray.get value.arena.session_links value.row)
    in
    Iarray.of_list (List.rev_map (window_at value.arena) rows)
end

module Window = struct
  type t = window

  module Id = Window_id

  type target = Id.t Target.t

  module Target = struct
    type t = target

    let source = Target.source
    let id = Target.id

    let of_id ~source:binding identifier : t =
      { source = binding; id = identifier }
  end

  let data (value : t) = Iarray.get value.arena.window_rows value.row
  let id value = (data value).id
  let name value = (data value).name
  let width value = (data value).width
  let height value = (data value).height
  let layout value = (data value).layout
  let source (value : t) = value.arena.source
  let target value = Target.of_id ~source:(source value) (id value)

  let same_entity a b =
    Source.equal (source a) (source b) && Id.equal (id a) (id b)

  let same_observation (a : t) (b : t) =
    same_entity a b && observation_equal a.arena b.arena

  let panes (value : t) =
    Iarray.map (pane_at value.arena)
      (Iarray.get value.arena.window_panes value.row)

  let links (value : t) =
    Iarray.map (link_at value.arena)
      (Iarray.get value.arena.window_links value.row)
end

module Window_link = struct
  type t = window_link

  let data (value : t) = Iarray.get value.arena.link_rows value.row
  let index value = (data value).index
  let is_current value = (data value).is_current

  let session (value : t) =
    session_at value.arena
      (String_map.find
         (Session_id.to_string (data value).session_id)
         value.arena.session_index)

  let window (value : t) =
    window_at value.arena
      (String_map.find
         (Window_id.to_string (data value).window_id)
         value.arena.window_index)

  let same_context (a : t) (b : t) =
    Source.equal a.arena.source b.arena.source
    && index a = index b
    && Session_id.equal (data a).session_id (data b).session_id
    && Window_id.equal (data a).window_id (data b).window_id

  let same_observation (a : t) (b : t) =
    same_context a b && observation_equal a.arena b.arena
end

module Pane = struct
  type t = pane

  module Id = Pane_id

  type target = Id.t Target.t

  module Target = struct
    type t = target

    let source = Target.source
    let id = Target.id

    let of_id ~source:binding identifier : t =
      { source = binding; id = identifier }
  end

  let data (value : t) = Iarray.get value.arena.pane_rows value.row
  let id value = (data value).id
  let index value = (data value).index
  let active value = (data value).active
  let dead value = (data value).dead
  let title value = (data value).title
  let current_command value = (data value).current_command
  let current_path value = (data value).current_path
  let pid value = (data value).pid
  let width value = (data value).width
  let height value = (data value).height
  let left value = (data value).left
  let top value = (data value).top
  let source (value : t) = value.arena.source
  let target value = Target.of_id ~source:(source value) (id value)

  let window (value : t) =
    window_at value.arena
      (String_map.find
         (Window_id.to_string (data value).window_id)
         value.arena.window_index)

  let same_entity a b =
    Source.equal (source a) (source b) && Id.equal (id a) (id b)

  let same_observation (a : t) (b : t) =
    same_entity a b && observation_equal a.arena b.arena
end

module Client_name = struct
  type t = { source : Source.t; name : string }

  let source t = t.source
  let to_string t = t.name
end

module Client_observation = struct
  type t = client

  let data (value : t) = Iarray.get value.arena.client_rows value.row
  let name value = (data value).name
  let pid value = (data value).pid
  let width value = (data value).width
  let height value = (data value).height
  let control_mode value = (data value).control_mode
  let source (value : t) = value.arena.source

  let current_name value =
    { Client_name.source = source value; name = name value }

  let session (value : t) =
    Option.map
      (fun id ->
        session_at value.arena
          (String_map.find (Session_id.to_string id) value.arena.session_index))
      (data value).session_id

  let same_observation (a : t) (b : t) =
    observation_equal a.arena b.arena && String.equal (name a) (name b)
end

module Snapshot = struct
  type t = arena

  module Id = Snapshot_id
  module Input = Rows

  let source value = value.source
  let id value = value.snapshot_id
  let started_at_ns value = value.started_at_ns
  let finished_at_ns value = value.finished_at_ns

  let sessions value =
    Iarray.init (Iarray.length value.session_rows) (session_at value)

  let windows value =
    Iarray.init (Iarray.length value.window_rows) (window_at value)

  let window_links value =
    Iarray.init (Iarray.length value.link_rows) (link_at value)

  let panes value = Iarray.init (Iarray.length value.pane_rows) (pane_at value)

  let clients value =
    Iarray.init (Iarray.length value.client_rows) (client_at value)

  let find_session value id =
    Option.map (session_at value)
      (String_map.find_opt (Session_id.to_string id) value.session_index)

  let find_window value id =
    Option.map (window_at value)
      (String_map.find_opt (Window_id.to_string id) value.window_index)

  let find_pane value id =
    Option.map (pane_at value)
      (String_map.find_opt (Pane_id.to_string id) value.pane_index)

  exception Invalid_capture of Error.t

  let reject message = raise (Invalid_capture (Error.Capture_raced message))

  let unique name key rows =
    let _, kept =
      List.fold_left
        (fun (seen, kept) row ->
          let id = key row in
          match String_map.find_opt id seen with
          | Some previous when previous = row -> (seen, kept)
          | Some _ -> reject ("conflicting " ^ name ^ " " ^ id)
          | None -> (String_map.add id row seen, row :: kept))
        (String_map.empty, []) rows
    in
    Iarray.of_list (List.rev kept)

  let index key rows =
    Iarray.fold_left
      (fun (next, map) row -> (next + 1, String_map.add (key row) next map))
      (0, String_map.empty) rows
    |> snd

  let require name map key =
    match String_map.find_opt key map with
    | Some index -> index
    | None -> reject ("dangling " ^ name ^ " " ^ key)

  let adjacency size rows parent =
    let lists = Array.make size [] in
    Iarray.iteri
      (fun i row ->
        let p = parent row in
        lists.(p) <- i :: lists.(p))
      rows;
    Iarray.init size (fun i -> Iarray.of_list (List.rev lists.(i)))

  let create ~source ~id ~started_at_ns ~finished_at_ns ~sessions ~windows
      ~window_links ~panes ~clients =
    let count =
      List.length sessions + List.length windows + List.length window_links
      + List.length panes + List.length clients
    in
    if count > 10_000 then
      Error (Error.Capacity { resource = "snapshot rows"; limit = 10_000 })
    else if started_at_ns < 0L || finished_at_ns < started_at_ns then
      Error (Error.Invalid_input "invalid monotonic capture interval")
    else
      try
        let session_rows =
          unique "session"
            (fun (s : Rows.session) -> Session_id.to_string s.id)
            sessions
        in
        let window_rows =
          unique "window"
            (fun (w : Rows.window) -> Window_id.to_string w.id)
            windows
        in
        let pane_rows =
          unique "pane" (fun (p : Rows.pane) -> Pane_id.to_string p.id) panes
        in
        let client_rows =
          unique "client" (fun (c : Rows.client) -> c.name) clients
        in
        let link_rows =
          unique "link"
            (fun (l : Rows.window_link) ->
              Session_id.to_string l.session_id ^ ":" ^ Int.to_string l.index)
            window_links
        in
        let session_index =
          index
            (fun (s : Rows.session) -> Session_id.to_string s.id)
            session_rows
        in
        let window_index =
          index (fun (w : Rows.window) -> Window_id.to_string w.id) window_rows
        in
        let pane_index =
          index (fun (p : Rows.pane) -> Pane_id.to_string p.id) pane_rows
        in
        Iarray.iter
          (fun (s : Rows.session) ->
            if s.attached < 0 then reject "negative session attachment count")
          session_rows;
        Iarray.iter
          (fun (w : Rows.window) ->
            if w.width <= 0 || w.height <= 0 then
              reject "invalid window geometry")
          window_rows;
        Iarray.iter
          (fun (p : Rows.pane) ->
            if
              p.index < 0
              || Option.fold ~none:false ~some:(fun pid -> pid <= 0) p.pid
              || p.width <= 0 || p.height <= 0 || p.left < 0 || p.top < 0
            then reject "invalid pane geometry, index or PID")
          pane_rows;
        Iarray.iter
          (fun (l : Rows.window_link) ->
            if l.index < 0 then reject "negative window index")
          link_rows;
        Iarray.iter
          (fun (c : Rows.client) ->
            if
              c.name = "" || c.pid <= 0 || c.width <= 0
              || Option.fold ~none:false
                   ~some:(fun height -> height <= 0)
                   c.height
            then reject "invalid client row";
            Option.iter
              (fun id ->
                ignore
                  (require "client session" session_index
                     (Session_id.to_string id)))
              c.session_id)
          client_rows;
        let session_links =
          adjacency (Iarray.length session_rows) link_rows
            (fun (l : Rows.window_link) ->
              require "link session" session_index
                (Session_id.to_string l.session_id))
        in
        let window_links =
          adjacency (Iarray.length window_rows) link_rows
            (fun (l : Rows.window_link) ->
              require "link window" window_index
                (Window_id.to_string l.window_id))
        in
        let window_panes =
          adjacency (Iarray.length window_rows) pane_rows
            (fun (p : Rows.pane) ->
              require "pane window" window_index
                (Window_id.to_string p.window_id))
        in
        Iarray.iter
          (fun links ->
            if Iarray.length links = 0 then
              reject "session without window links";
            let current =
              Iarray.fold_left
                (fun n i ->
                  if (Iarray.get link_rows i).is_current then n + 1 else n)
                0 links
            in
            if current <> 1 then
              reject "session must have one current window link")
          session_links;
        Iarray.iteri
          (fun i pane_indexes ->
            if Iarray.length (Iarray.get window_links i) = 0 then
              reject "window without session links";
            if Iarray.length pane_indexes = 0 then reject "window without panes";
            let active, _ =
              Iarray.fold_left
                (fun (active, seen) i ->
                  let p = Iarray.get pane_rows i in
                  let key = Int.to_string p.index in
                  if String_map.mem key seen then
                    reject "duplicate pane index within window";
                  ( (if p.active then active + 1 else active),
                    String_map.add key () seen ))
                (0, String_map.empty) pane_indexes
            in
            if active <> 1 then reject "window must have one active pane")
          window_panes;
        Ok
          {
            source;
            snapshot_id = id;
            started_at_ns;
            finished_at_ns;
            session_rows;
            window_rows;
            link_rows;
            pane_rows;
            client_rows;
            session_index;
            window_index;
            pane_index;
            session_links;
            window_links;
            window_panes;
          }
      with Invalid_capture error -> Error error
end
