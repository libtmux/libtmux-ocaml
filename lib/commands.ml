module Source = Graph.Source
module Session = Graph.Session
module Window = Graph.Window
module Pane = Graph.Pane
module Snapshot = Graph.Snapshot
module Client_name = Graph.Client_name

module Captured_text = struct
  type t = {
    bytes : string;
    source : Source.t;
    pane : Pane.Id.t;
    started_at_ns : int64;
    finished_at_ns : int64;
  }
end

module Key = struct
  type t =
    | Enter
    | Tab
    | Escape
    | Backspace
    | Up
    | Down
    | Left
    | Right
    | Control of char
end

module Spawn = struct
  type command =
    | Default
    | Exec of { program : string; args : string list }
    | Shell of string

  type t = {
    command : command;
    cwd : string option;
    environment : (string * string) list;
  }

  let make ?cwd ?(environment = []) command = { command; cwd; environment }
  let default = make Default
end

module Geometry = struct
  type direction = Left | Right | Above | Below
  type size = Cells of int | Percent of int
end

module Layout = struct
  type t =
    | Even_horizontal
    | Even_vertical
    | Main_horizontal
    | Main_vertical
    | Tiled
    | Custom of string
end

module Created = struct
  type t = {
    session : Session.target;
    window : Window.target;
    pane : Pane.target;
    window_index : int;
    pane_index : int;
  }
end

module Environment = struct
  type scope = Global | Session of Session.target
  type value = Value of string | Removed
  type entry = { name : string; value : value }

  type t = {
    source : Source.t;
    scope : scope;
    hidden : bool;
    entries : entry Iarray.t;
    started_at_ns : int64;
    finished_at_ns : int64;
  }

  let lookup t name =
    Iarray.find_opt (fun entry -> entry.name = name) t.entries
    |> Option.map (fun entry -> entry.value)
end

module Hook = struct
  type command = { name : string; arguments : string list }
end

module Command = struct
  type mutation =
    | Kill_session of Session.target
    | Kill_window of Window.target
    | Kill_pane of Pane.target
    | Select_window_at of Session.target * int
    | Unlink_window_at of {
        session : Session.target;
        index : int;
        allow_kill : bool;
      }
    | Link_window of {
        window : Window.target;
        session : Session.target;
        index : int;
      }
    | Move_window_at of {
        from_session : Session.target;
        from_index : int;
        session : Session.target;
        index : int;
      }
    | Select_pane of Pane.target
    | Set_pane_title of Pane.target * string
    | Resize_pane of {
        pane : Pane.target;
        width : int option;
        height : int option;
      }
    | Resize_window of {
        window : Window.target;
        width : int option;
        height : int option;
      }
    | Select_layout of Window.target * Layout.t
    | Cycle_layout of Window.target * [ `Next | `Previous ]
    | Move_pane of {
        pane : Pane.target;
        beside : Pane.target;
        direction : Geometry.direction;
        size : Geometry.size option;
      }
    | Swap_panes of Pane.target * Pane.target
    | Rotate_panes of Window.target * [ `Forward | `Backward ]
    | Zoom_pane of Pane.target
    | Respawn_pane of {
        pane : Pane.target;
        spawn : Spawn.t;
        kill_running : bool;
      }
    | Clear_history of Pane.target
    | Set_environment of {
        scope : Environment.scope;
        name : string;
        value : string;
        hidden : bool;
      }
    | Unset_environment of Environment.scope * string
    | Remove_environment of Environment.scope * string
    | Set_option of {
        scope : Options.scope;
        name : string;
        index : int option;
        value : Options.scalar;
        append : bool;
      }
    | Unset_option of Options.scope * string * int option
    | Clear_option_array of Options.scope * string
    | Set_hook of {
        scope : Options.scope;
        name : string;
        index : int option;
        commands : Hook.command list;
        append : bool;
      }
    | Remove_hook of Options.scope * string * int option
    | Run_hook of Options.scope * string
    | Switch_client_at of {
        client : Client_name.t;
        session : Session.target;
        update_environment : bool;
      }
    | Request_detach_client_at of Client_name.t
    | Refresh_client_at of Client_name.t * bool
    | Resize_control_client_at of {
        client : Client_name.t;
        width : int;
        height : int;
      }

  type _ view =
    | Capture : Snapshot.t view
    | Capture_text : {
        pane : Pane.t;
        start : int;
        end_ : int;
        scratch_dir : string;
      }
        -> Captured_text.t view
    | Rename_window : Window.target * string -> unit view
    | Rename_session : Session.target * string -> unit view
    | Send_text : Pane.target * string -> unit view
    | Send_keys : Pane.target * Key.t list -> unit view
    | Wait_for : string -> unit view
    | Signal : string -> unit view
    | Capture_environment : Environment.scope * bool -> Environment.t view
    | Capture_options : Options.scope * bool -> Options.t view
    | Read_option : Options.scope * string * bool -> Options.value option view
    | Capture_hooks : Options.scope -> Options.t view
    | Read_hook : Options.scope * string * bool -> Options.value option view
    | Mutate : mutation -> unit view
    | Create_session : {
        name : string;
        window_name : string option;
        width : int;
        height : int;
        spawn : Spawn.t;
      }
        -> Created.t view
    | Create_window : {
        session : Session.target;
        index : int option;
        name : string option;
        spawn : Spawn.t;
      }
        -> Created.t view
    | Split_pane : {
        pane : Pane.target;
        direction : Geometry.direction;
        size : Geometry.size option;
        spawn : Spawn.t;
      }
        -> Created.t view
    | Break_pane : {
        pane : Pane.target;
        session : Session.target;
        index : int;
        name : string option;
      }
        -> Created.t view

  type 'a t = 'a view

  let view command = command
end

module Operations = struct
  let capture () = Command.Capture

  let capture_text ?(scratch_dir = "/tmp") pane ~start ~end_ =
    Command.Capture_text { pane; start; end_; scratch_dir }

  let rename_window target ~name = Command.Rename_window (target, name)
  let rename_session target ~name = Command.Rename_session (target, name)

  let switch_client_at ?(update_environment = false) client ~session =
    Command.Mutate (Switch_client_at { client; session; update_environment })

  let request_detach_client_at client =
    Command.Mutate (Request_detach_client_at client)

  let refresh_client_at ?(status_only = false) client =
    Command.Mutate (Refresh_client_at (client, status_only))

  let resize_control_client_at client ~width ~height =
    Command.Mutate (Resize_control_client_at { client; width; height })

  let send_text target ~text = Command.Send_text (target, text)
  let send_keys target keys = Command.Send_keys (target, keys)
  let wait_for channel = Command.Wait_for channel
  let signal channel = Command.Signal channel

  let capture_environment ?(hidden = false) scope =
    Command.Capture_environment (scope, hidden)

  let set_environment ?(hidden = false) scope ~name value =
    Command.Mutate (Set_environment { scope; name; value; hidden })

  let unset_environment scope name =
    Command.Mutate (Unset_environment (scope, name))

  let remove_environment scope name =
    Command.Mutate (Remove_environment (scope, name))

  let capture_options ?(include_inherited = false) scope =
    Command.Capture_options (scope, include_inherited)

  let read_option ?(include_inherited = true) scope name =
    Command.Read_option (scope, name, include_inherited)

  let set_option ?index ?(append = false) scope ~name value =
    Command.Mutate (Set_option { scope; name; index; value; append })

  let unset_option ?index scope name =
    Command.Mutate (Unset_option (scope, name, index))

  let clear_option_array scope name =
    Command.Mutate (Clear_option_array (scope, name))

  let capture_hooks scope = Command.Capture_hooks scope

  let read_hook ?(include_inherited = true) scope name =
    Command.Read_hook (scope, name, include_inherited)

  let set_hook ?index ?(append = false) scope ~name commands =
    Command.Mutate (Set_hook { scope; name; index; commands; append })

  let remove_hook ?index scope name =
    Command.Mutate (Remove_hook (scope, name, index))

  let run_hook scope name = Command.Mutate (Run_hook (scope, name))

  let create_session ?window_name ?(width = 80) ?(height = 24)
      ?(spawn = Spawn.default) ~name () =
    Command.Create_session { name; window_name; width; height; spawn }

  let create_window ?index ?name ?(spawn = Spawn.default) session =
    Command.Create_window { session; index; name; spawn }

  let split_pane ?size ?(spawn = Spawn.default) pane ~direction =
    Command.Split_pane { pane; direction; size; spawn }

  let break_pane ?name pane ~session ~index =
    Command.Break_pane { pane; session; index; name }

  let kill_session session = Command.Mutate (Kill_session session)
  let kill_window window = Command.Mutate (Kill_window window)
  let kill_pane pane = Command.Mutate (Kill_pane pane)

  let select_window_at session ~index =
    Command.Mutate (Select_window_at (session, index))

  let unlink_window_at ?(allow_kill = false) session ~index =
    Command.Mutate (Unlink_window_at { session; index; allow_kill })

  let link_window window ~session ~index =
    Command.Mutate (Link_window { window; session; index })

  let move_window_at from_session ~from_index ~session ~index =
    Command.Mutate (Move_window_at { from_session; from_index; session; index })

  let select_pane pane = Command.Mutate (Select_pane pane)
  let set_pane_title pane ~title = Command.Mutate (Set_pane_title (pane, title))

  let resize_pane ?width ?height pane =
    Command.Mutate (Resize_pane { pane; width; height })

  let resize_window ?width ?height window =
    Command.Mutate (Resize_window { window; width; height })

  let select_layout window layout =
    Command.Mutate (Select_layout (window, layout))

  let cycle_layout window direction =
    Command.Mutate (Cycle_layout (window, direction))

  let move_pane ?size pane ~beside ~direction =
    Command.Mutate (Move_pane { pane; beside; direction; size })

  let swap_panes pane other = Command.Mutate (Swap_panes (pane, other))

  let rotate_panes window direction =
    Command.Mutate (Rotate_panes (window, direction))

  let zoom_pane pane = Command.Mutate (Zoom_pane pane)

  let respawn_pane ?(kill_running = false) pane spawn =
    Command.Mutate (Respawn_pane { pane; spawn; kill_running })

  let clear_history pane = Command.Mutate (Clear_history pane)
end
