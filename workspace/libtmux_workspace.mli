(** Workspace validation and planning are pure. Execution delegates I/O to an
    explicit executor. *)

module Config : sig
  type error = { path : string; message : string }

  val pp_error : Format.formatter -> error -> unit

  type setting = {
    name : string;
    index : int option;
    value : Libtmux.Options.scalar;
  }

  type pane = {
    spawn : Libtmux.Spawn.t;
    options : setting list;
    startup : string list;
    direction : Libtmux.Geometry.direction;
    size : Libtmux.Geometry.size option;
  }

  type window = {
    name : string;
    cwd : string option;
    environment : (string * string) list;
    options : setting list;
    panes : pane list;
    layout : Libtmux.Layout.t option;
  }

  type t

  val pane :
    ?spawn:Libtmux.Spawn.t ->
    ?options:setting list ->
    ?startup:string list ->
    ?direction:Libtmux.Geometry.direction ->
    ?size:Libtmux.Geometry.size ->
    unit ->
    pane

  val window :
    ?cwd:string ->
    ?environment:(string * string) list ->
    ?options:setting list ->
    ?layout:Libtmux.Layout.t ->
    name:string ->
    pane list ->
    window
  (** Builders are unchecked descriptions; [make] validates the whole document.
  *)

  val make :
    ?cwd:string ->
    ?environment:(string * string) list ->
    ?options:setting list ->
    ?variables:(string * string) list ->
    ?width:int ->
    ?height:int ->
    directory:string ->
    session:string ->
    window list ->
    (t, error) result
  (** Resolve relative working directories against the absolute document
      directory. Explicit variables expand [${NAME}] in directories only; they
      never read the process environment. Cycles and unknown names fail. Command
      arguments, shell code, startup text and environment values remain literal.

      At most 64 windows, 256 total panes and 1 MiB of text are accepted. Names
      and settings must be unique in their scope. No filesystem is consulted. *)

  val session : t -> string
  val windows : t -> window Iarray.t
  val environment : t -> (string * string) list
  val options : t -> setting list
  val dimensions : t -> int * int
end

module Plan : sig
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

  val pp_error : Format.formatter -> error -> unit

  type scope = Session | Window of int | Pane of { window : int; pane : int }

  type action =
    | Create_session of {
        bootstrap : bool;
        name : string;
        window_name : string;
        spawn : Libtmux.Spawn.t;
        width : int;
        height : int;
      }
    | Create_window of { window : int; name : string; spawn : Libtmux.Spawn.t }
    | Split_pane of {
        window : int;
        pane : int;
        spawn : Libtmux.Spawn.t;
        direction : Libtmux.Geometry.direction;
        size : Libtmux.Geometry.size option;
      }
    | Set_environment of string * string
    | Set_option of scope * Config.setting
    | Send_text of { window : int; pane : int; text : string }
    | Send_enter of { window : int; pane : int }
    | Select_layout of int * Libtmux.Layout.t

  type t

  val make :
    ?server_policy:server_policy ->
    ?collision_policy:collision_policy ->
    endpoint:Libtmux.Endpoint.t ->
    version:string ->
    observed:Libtmux.Snapshot.t option ->
    Config.t ->
    (t, error) result
  (** [None] means an explicitly observed missing endpoint. It is not an empty
      successful snapshot. A plan does not start a server. Append rejects any
      existing requested window name and never changes session options.
      [version] selects the generated option catalog. *)

  val endpoint : t -> Libtmux.Endpoint.t
  val source : t -> Libtmux.Source.t option
  val existing_session : t -> Libtmux.Session.target option
  val actions : t -> action Iarray.t
  val config : t -> Config.t

  val check_source : t -> Libtmux.Source.t option -> (unit, error) result
  (** Operational plans are ephemeral and bound to one connection generation. A
      printed or serialized preview cannot supply operational targets. *)
end

module Execution : sig
  type resource =
    | Session of Libtmux.Session.target
    | Window of Libtmux.Window.target
    | Pane of Libtmux.Pane.target

  type hint = {
    session : Libtmux.Session.Id.t;
    window : Libtmux.Window.Id.t;
    pane : Libtmux.Pane.Id.t;
    window_index : int;
    pane_index : int;
    server_pid : int;
  }
  (** A creation row received before daemon binding finished. Hints are not
      operational targets and are never eligible for automatic compensation. *)

  type certainty = Not_started | Applied | Unknown

  type observation = {
    certainty : certainty;
    created : Libtmux.Created.t list;
    unbound : hint option;
  }

  type executor = {
    source : unit -> Libtmux.Source.t option;
    capture : unit -> (Libtmux.Snapshot.t, Libtmux.Error.t) result;
    run : 'a. 'a Libtmux.Command.t -> ('a, Libtmux.Error.t) result;
    bootstrap : Config.t -> (Libtmux.Created.t, Libtmux.Error.t) result;
    inspect : unit -> unit -> observation;
    protect : (unit -> unit) -> (unit, Libtmux.Error.t) result;
  }
  (** Backend integration: [inspect] returns a callback tied to the latest
      operation, reading only its retained state even after later submissions.
      [protect] bounds compensation and shields it from caller cancellation,
      reporting expected failures as [Error]. Ordinary callers use their
      backend's Workspace API. *)

  type step_status =
    | Pending
    | Running
    | Completed
    | Failed of Libtmux.Error.t
    | Skipped
    | Uncertain of Libtmux.Error.t

  type step = {
    index : int;
    action : Plan.action;
    status : step_status;
    created : Libtmux.Created.t list;
    unbound : hint option;
  }

  type cleanup = {
    resource : resource;
    outcome : (unit, Libtmux.Error.t) result;
  }

  type status =
    | Queued
    | Applying
    | Succeeded
    | Partial
    | Interrupted
    | Rejected of Plan.error
    | Unavailable of Libtmux.Error.t

  type receipt = {
    operation_id : string;
    source : Libtmux.Source.t option;
    status : status;
    steps : step Iarray.t;
    cleanup : cleanup Iarray.t;
    cleanup_error : Libtmux.Error.t option;
  }

  type t

  val create :
    operation_id:string ->
    executor:executor ->
    Plan.t ->
    (t, Libtmux.Error.t) result
  (** Allocate a retained handle without I/O. IDs have 1..64 ASCII letters,
      digits, underscores or hyphens. *)

  val inspect : t -> receipt
  (** Return an immutable copy of the retained journal without I/O. *)

  val await : ?compensate_on_failure:bool -> t -> receipt
  (** Execute once, rechecking generation and captured preconditions first.
      Expected failures return a partial journal. Exceptions, including native
      cancellation, propagate after recording progress and bounded compensation.
      Subsequent calls only return the retained receipt; mutations never retry.

      Compensation removes only proven newly created resources in reverse order.
      New containers cover their created children. Pre-existing sessions in
      append mode are retained. Cleanup failures have separate outcomes. *)
end
