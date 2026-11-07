open Libtmux

type server_policy = Create_if_missing | Require_existing_server
type window_collision = Reject

type collision_policy =
  | Fail_if_session_exists
  | Append_new_windows of { window_collision : window_collision }

type error =
  | Missing_endpoint
  | Session_conflict of string
  | Window_conflict of string
  | Append_session_options
  | Too_many_steps
  | Unsupported_setting of Config.error
  | Stale

let pp_error formatter = function
  | Missing_endpoint ->
      Format.pp_print_string formatter "required endpoint is missing"
  | Session_conflict name ->
      Format.fprintf formatter "session already exists: %s" name
  | Window_conflict name ->
      Format.fprintf formatter "window already exists: %s" name
  | Append_session_options ->
      Format.pp_print_string formatter
        "append cannot change existing session options"
  | Too_many_steps ->
      Format.pp_print_string formatter "workspace exceeds 4096 steps"
  | Unsupported_setting error -> Config.pp_error formatter error
  | Stale ->
      Format.pp_print_string formatter
        "plan belongs to another endpoint or connection generation"

type scope = Session | Window of int | Pane of { window : int; pane : int }

type action =
  | Create_session of {
      bootstrap : bool;
      name : string;
      window_name : string;
      spawn : Spawn.t;
      width : int;
      height : int;
    }
  | Create_window of { window : int; name : string; spawn : Spawn.t }
  | Split_pane of {
      window : int;
      pane : int;
      spawn : Spawn.t;
      direction : Geometry.direction;
      size : Geometry.size option;
    }
  | Set_environment of string * string
  | Set_option of scope * Config.setting
  | Send_text of { window : int; pane : int; text : string }
  | Send_enter of { window : int; pane : int }
  | Select_layout of int * Layout.t

type t = {
  endpoint : Endpoint.t;
  source : Source.t option;
  existing_session : Session.target option;
  actions : action Iarray.t;
  config : Config.t;
  version : string;
  server_policy : server_policy;
  collision_policy : collision_policy;
}

exception Invalid of error

let fail error = raise (Invalid error)

let make ?(server_policy = Create_if_missing)
    ?(collision_policy = Fail_if_session_exists) ~endpoint ~version ~observed
    config =
  try
    let source = Option.map Snapshot.source observed in
    Option.iter
      (fun source ->
        if not (Endpoint.equal endpoint (Source.endpoint source)) then
          fail Stale)
      source;
    if Option.is_none observed && server_policy = Require_existing_server then
      fail Missing_endpoint;
    let existing =
      Option.bind observed (fun snapshot ->
          Snapshot.sessions snapshot
          |> Iarray.find_opt (fun session ->
              Session.name session = Config.session config))
    in
    (match (existing, collision_policy) with
    | Some _, Fail_if_session_exists ->
        fail (Session_conflict (Config.session config))
    | Some session, Append_new_windows _ ->
        if Config.options config <> [] then fail Append_session_options;
        Iarray.iter
          (fun (window : Config.window) ->
            if
              Session.windows session
              |> Iarray.exists (fun old -> Window.name old = window.name)
            then fail (Window_conflict window.name))
          (Config.windows config)
    | None, _ -> ());
    let actions = ref [] in
    let count = ref 0 in
    let add action =
      incr count;
      if !count > 4096 then fail Too_many_steps;
      actions := action :: !actions
    in
    let settings scope kind values =
      List.iter
        (fun (setting : Config.setting) ->
          let bad message =
            fail
              (Unsupported_setting
                 { path = "/options/" ^ setting.name; message })
          in
          let descriptor =
            match Options.describe ~version setting.name with
            | Ok d -> d
            | Error error -> bad (Format.asprintf "%a" Error.pp error)
          in
          if descriptor.hook || not (List.mem kind descriptor.scopes) then
            bad "option is unavailable in this scope";
          if descriptor.array <> Option.is_some setting.index then
            bad "array options require an explicit index";
          let correct =
            match (descriptor.kind, setting.value) with
            | Options.Kind.Text, Options.Text _
            | Number, Integer _
            | Flag, Bool _
            | Choice, Choice _
            | Key, Key _
            | Colour, Colour _
            | Commands, Commands _ ->
                true
            | _ -> false
          in
          if not correct then bad "option value has the wrong scalar kind";
          add (Set_option (scope, setting)))
        values
    in
    let windows = Config.windows config in
    (match existing with
    | Some _ -> ()
    | None ->
        let first = Iarray.get windows 0 in
        let width, height = Config.dimensions config in
        add
          (Create_session
             {
               bootstrap = Option.is_none observed;
               name = Config.session config;
               window_name = first.name;
               spawn = (List.hd first.panes).spawn;
               width;
               height;
             });
        List.iter
          (fun (key, value) -> add (Set_environment (key, value)))
          (Config.environment config);
        settings Session `Session (Config.options config));
    Iarray.iteri
      (fun wi (window : Config.window) ->
        if wi <> 0 || Option.is_some existing then
          add
            (Create_window
               {
                 window = wi;
                 name = window.name;
                 spawn = (List.hd window.panes).spawn;
               });
        settings (Window wi) `Window window.options;
        List.iteri
          (fun pi (pane : Config.pane) ->
            if pi <> 0 then
              add
                (Split_pane
                   {
                     window = wi;
                     pane = pi;
                     spawn = pane.spawn;
                     direction = pane.direction;
                     size = pane.size;
                   });
            settings (Pane { window = wi; pane = pi }) `Pane pane.options;
            List.iter
              (fun text ->
                add (Send_text { window = wi; pane = pi; text });
                add (Send_enter { window = wi; pane = pi }))
              pane.startup)
          window.panes;
        Option.iter
          (fun layout -> add (Select_layout (wi, layout)))
          window.layout)
      windows;
    Ok
      {
        endpoint;
        source;
        existing_session = Option.map Session.target existing;
        actions = Iarray.of_list (List.rev !actions);
        config;
        version;
        server_policy;
        collision_policy;
      }
  with Invalid error -> Error error

let endpoint t = t.endpoint
let source t = t.source
let existing_session t = t.existing_session
let actions t = t.actions
let config t = t.config

let check_source t actual =
  match (t.source, actual) with
  | None, None -> Ok ()
  | Some expected, Some actual when Source.equal expected actual -> Ok ()
  | _ -> Error Stale

let recheck t snapshot =
  match check_source t (Some (Snapshot.source snapshot)) with
  | Error error -> Error error
  | Ok () ->
      Result.bind
        (make ~server_policy:t.server_policy
           ~collision_policy:t.collision_policy ~endpoint:t.endpoint
           ~version:t.version ~observed:(Some snapshot) t.config) (fun fresh ->
          match (t.existing_session, fresh.existing_session) with
          | None, None -> Ok ()
          | Some before, Some after
            when Session.Id.equal (Session.Target.id before)
                   (Session.Target.id after) ->
              Ok ()
          | _ -> Error Stale)
