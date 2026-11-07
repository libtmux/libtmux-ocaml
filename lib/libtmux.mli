(** Pure values and collection operations. This module performs no I/O. *)

module Endpoint : sig
  type t
  (** An explicit socket description, independent of the environment. *)

  type kind = Named_socket of string | Socket_path of string

  val named_socket : string -> t
  (** [named_socket name] describes tmux's [-L name] endpoint. Raises
      [Invalid_argument] if [name] is empty or contains NUL or [/]. *)

  val socket_path : string -> t
  (** [socket_path path] describes an absolute [-S path] endpoint. It does not
      check existence or resolve symbolic links. Raises [Invalid_argument] if
      [path] is relative, empty or contains NUL. *)

  val kind : t -> kind

  val equal : t -> t -> bool
  (** Equality compares descriptions, not server instances or resolved paths. *)

  val pp : Format.formatter -> t -> unit
end

module Error : sig
  type t =
    | Invalid_input of string
    | Malformed_data of string
    | Capture_raced of string
    | Unsupported_version of string
    | Unsupported_binding of string
    | Unsupported_capture_hooks
    | Unsupported of string
    | Closed
    | Disconnected of string
    | Filesystem of { operation : string; message : string }
    | Wrong_domain
    | Busy
    | Capacity of { resource : string; limit : int }
    | Stale_target
    | No_such_entity of { kind : string; id : string }
    | Command_failed of { command : string; message : string }
    | Deadline_exceeded
    | Not_started
    | Outcome_unknown of string

  val pp : Format.formatter -> t -> unit
end

module Generation : sig
  type t

  val of_string : string -> (t, Error.t) result
  (** Import a 256-bit connection nonce as 64 lowercase hexadecimal characters.
      Backends generate a fresh random nonce for each connection. *)

  val to_string : t -> string
  val equal : t -> t -> bool
end

module Source : sig
  type t

  val create :
    endpoint:Endpoint.t ->
    generation:Generation.t ->
    server_pid:int ->
    (t, Error.t) result
  (** Pure metadata import for capture adapters. This neither establishes a
      connection nor verifies process identity. The backend must bind the
      generation to a live daemon before it admits operations. *)

  val endpoint : t -> Endpoint.t
  val generation : t -> Generation.t
  val server_pid : t -> int
  val equal : t -> t -> bool
end

module Client_name : sig
  type t
  (** A name in one connection generation, with current-name semantics. It does
      not identify a stable client incarnation; tmux may reuse client names. *)

  val source : t -> Source.t
  val to_string : t -> string
end

module type ID = sig
  type t

  val of_string : string -> (t, Error.t) result
  (** Accept a canonical prefixed decimal tmux ID in the uint32 range. *)

  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Field : sig
  type _ kind = Bool : bool kind | Int : int kind | Text : string kind
  type ('entity, 'value) t
  type 'entity packed = Pack : ('entity, 'value) t -> 'entity packed

  val name : ('entity, 'value) t -> string
  val kind : ('entity, 'value) t -> 'value kind

  val get : ('entity, 'value) t -> 'entity -> 'value
  (** Canonical descriptors are sealed. Accessing a field reads captured data.
  *)
end

module Relation : sig
  module Many : sig
    type ('parent, 'child) t

    val name : ('parent, 'child) t -> string
  end

  module One : sig
    type ('parent, 'child) t

    val name : ('parent, 'child) t -> string
  end

  module Optional : sig
    type ('parent, 'child) t

    val name : ('parent, 'child) t -> string
  end
end

module rec Session : sig
  type t

  module Fields : sig
    val id : (t, string) Field.t
    val name : (t, string) Field.t
    val attached : (t, int) Field.t
  end

  module Relations : sig
    val window_links : (t, Window_link.t) Relation.Many.t
    val windows : (t, Window.t) Relation.Many.t
  end

  module Id : ID

  module Target : sig
    type t

    val of_id : source:Source.t -> Id.t -> t
    (** Describe a target in an existing connection generation. No I/O. *)

    val source : t -> Source.t
    val id : t -> Id.t
  end

  type target = Target.t

  val id : t -> Id.t
  val name : t -> string
  val attached : t -> int
  val source : t -> Source.t
  val target : t -> target
  val same_entity : t -> t -> bool
  val same_observation : t -> t -> bool

  val window_links : t -> Window_link.t Iarray.t
  (** All captured links, in capture order, including repeated windows. *)

  val windows : t -> Window.t Iarray.t
  (** Distinct windows in first-link order. All accesses are local. *)
end

and Window : sig
  type t

  module Fields : sig
    val id : (t, string) Field.t
    val name : (t, string) Field.t
    val width : (t, int) Field.t
    val height : (t, int) Field.t
    val layout : (t, string) Field.t
  end

  module Relations : sig
    val panes : (t, Pane.t) Relation.Many.t
    val links : (t, Window_link.t) Relation.Many.t
  end

  module Id : ID

  module Target : sig
    type t

    val of_id : source:Source.t -> Id.t -> t
    val source : t -> Source.t
    val id : t -> Id.t
  end

  type target = Target.t

  val id : t -> Id.t
  val name : t -> string
  val width : t -> int
  val height : t -> int
  val layout : t -> string
  val source : t -> Source.t
  val target : t -> target
  val same_entity : t -> t -> bool
  val same_observation : t -> t -> bool
  val panes : t -> Pane.t Iarray.t
  val links : t -> Window_link.t Iarray.t
end

and Window_link : sig
  type t

  module Fields : sig
    val index : (t, int) Field.t
    val is_current : (t, bool) Field.t
  end

  module Relations : sig
    val session : (t, Session.t) Relation.One.t
    val window : (t, Window.t) Relation.One.t
  end

  val index : t -> int
  val is_current : t -> bool
  val session : t -> Session.t
  val window : t -> Window.t

  val same_context : t -> t -> bool
  (** Compare source, session, index and window. An equal context does not
      certify a stable link incarnation across reindexing or unlink/relink. *)

  val same_observation : t -> t -> bool
end

and Pane : sig
  type t

  module Fields : sig
    val id : (t, string) Field.t
    val index : (t, int) Field.t
    val active : (t, bool) Field.t
    val dead : (t, bool) Field.t
    val title : (t, string) Field.t
    val current_command : (t, string) Field.t
    val current_path : (t, string) Field.t
    val width : (t, int) Field.t
    val height : (t, int) Field.t
    val left : (t, int) Field.t
    val top : (t, int) Field.t
  end

  module Relations : sig
    val window : (t, Window.t) Relation.One.t
  end

  module Id : ID

  module Target : sig
    type t

    val of_id : source:Source.t -> Id.t -> t
    val source : t -> Source.t
    val id : t -> Id.t
  end

  type target = Target.t

  val id : t -> Id.t
  val index : t -> int
  val active : t -> bool
  val dead : t -> bool
  val title : t -> string
  val current_command : t -> string
  val current_path : t -> string

  val pid : t -> int option
  (** The captured process ID, absent when tmux reports no process. *)

  val width : t -> int
  val height : t -> int
  val left : t -> int
  val top : t -> int
  val window : t -> Window.t
  val source : t -> Source.t
  val target : t -> target
  val same_entity : t -> t -> bool
  val same_observation : t -> t -> bool
end

and Client_observation : sig
  type t

  module Fields : sig
    val name : (t, string) Field.t
    val pid : (t, int) Field.t
    val width : (t, int) Field.t
    val control_mode : (t, bool) Field.t
  end

  module Relations : sig
    val session : (t, Session.t) Relation.Optional.t
  end

  val name : t -> string
  val pid : t -> int
  val width : t -> int

  val height : t -> int option
  (** No height is reported until the client has a started terminal. *)

  val control_mode : t -> bool
  val source : t -> Source.t

  val current_name : t -> Client_name.t
  (** Address whichever client has this name when a command executes. *)

  val session : t -> Session.t option
  (** [None] means the captured client has no attached session. *)

  val same_observation : t -> t -> bool
  (** Client names may be reused. No cross-snapshot entity equality is offered.
  *)
end

module Snapshot : sig
  type t

  module Id : sig
    type t

    val of_string : string -> (t, Error.t) result
    val to_string : t -> string
    val equal : t -> t -> bool
  end

  module Input : sig
    type session = { id : Session.Id.t; name : string; attached : int }

    type window = {
      id : Window.Id.t;
      name : string;
      width : int;
      height : int;
      layout : string;
    }

    type window_link = {
      session_id : Session.Id.t;
      window_id : Window.Id.t;
      index : int;
      is_current : bool;
    }

    type pane = {
      id : Pane.Id.t;
      window_id : Window.Id.t;
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
      session_id : Session.Id.t option;
      pid : int;
      width : int;
      height : int option;
      control_mode : bool;
    }
  end

  val create :
    source:Source.t ->
    id:Id.t ->
    started_at_ns:int64 ->
    finished_at_ns:int64 ->
    sessions:Input.session list ->
    windows:Input.window list ->
    window_links:Input.window_link list ->
    panes:Input.pane list ->
    clients:Input.client list ->
    (t, Error.t) result
  (** Validate and materialize a complete captured graph without I/O. Equal
      duplicate global rows collapse in first-occurrence order; conflicting rows
      and dangling references return [Capture_raced]. Links at different indexes
      remain distinct, including within one session. At most 10,000 input rows
      are admitted. Each session needs one current link and each window one
      active pane. Capture spans an interval, not an atomic instant. Input
      strings are bytes; no Unicode normalization is performed. *)

  val id : t -> Id.t
  val source : t -> Source.t
  val started_at_ns : t -> int64
  val finished_at_ns : t -> int64
  val sessions : t -> Session.t Iarray.t
  val windows : t -> Window.t Iarray.t
  val window_links : t -> Window_link.t Iarray.t
  val panes : t -> Pane.t Iarray.t

  val clients : t -> Client_observation.t Iarray.t
  (** Collections and their contents are immutable. They retain capture order,
      are replayable and remain readable after the acquiring client closes. *)

  val find_session : t -> Session.Id.t -> Session.t option
  val find_window : t -> Window.Id.t -> Window.t option
  val find_pane : t -> Pane.Id.t -> Pane.t option
end

module Formats : sig
  module Kind : sig
    type t = Text | Timestamp
  end

  module Context : sig
    type t =
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

  type descriptor = {
    name : string;
    kind : Kind.t;
    contexts : Context.t list;
    versions : string list;
  }
  (** Metadata generated from pinned tmux format callbacks. [contexts] lists
      direct context dependencies, not a promise that a value exists. Caller
      variables from hooks and menus are outside this built-in catalog. *)

  type observation =
    | Snapshot of Snapshot.t
    | Session of Session.t
    | Window of Window.t
    | Window_link of Window_link.t
    | Pane of Pane.t
    | Client of Client_observation.t

  type scalar = Bool of bool | Int of int | Text of string

  type state =
    | Value of scalar
    | Missing
    | Unacquired
    | Unsupported
        (** [Missing] is an absence explicitly recorded in the observation, such
            as a client without terminal height. [Unacquired] means no captured
            value for this observation, including ambiguous session context for
            a pane. [Unsupported] means the name is outside the selected
            release's catalog. [Value (Text "")] is a captured empty string,
            never inferred absence. *)

  val catalog : version:string -> (descriptor Iarray.t, Error.t) result
  val describe : version:string -> string -> (descriptor option, Error.t) result

  val lookup :
    version:string -> observation -> string -> (state, Error.t) result
  (** No I/O. Supply the version recorded by the acquiring client's [version]
      accessor. Unsupported catalog versions return an error. Native typed
      accessors remain the primary API; lookup does not acquire extra fields. *)
end

module Model : sig
  type 'a t

  val session : Session.t t
  val window : Window.t t
  val window_link : Window_link.t t
  val pane : Pane.t t
  val client : Client_observation.t t
  val name : 'a t -> string
  val fields : 'a t -> 'a Field.packed list
  val find_field : 'a t -> string -> 'a Field.packed option
end

module Expr : sig
  type 'entity t

  val all : 'a t list -> 'a t
  (** Boolean conjunction; the empty conjunction is true. *)

  val any : 'a t list -> 'a t
  (** Boolean disjunction; the empty disjunction is false. *)

  val not_ : 'a t -> 'a t

  module Bool : sig
    val equal : ('a, bool) Field.t -> bool -> 'a t
    val is_true : ('a, bool) Field.t -> 'a t
    val is_false : ('a, bool) Field.t -> 'a t
  end

  module Int : sig
    val equal : ('a, int) Field.t -> int -> 'a t
    val lt : ('a, int) Field.t -> int -> 'a t
    val le : ('a, int) Field.t -> int -> 'a t
    val gt : ('a, int) Field.t -> int -> 'a t
    val ge : ('a, int) Field.t -> int -> 'a t
    val is_in : ('a, int) Field.t -> int list -> 'a t
  end

  module Text : sig
    val equal : ('a, string) Field.t -> string -> 'a t
    val starts_with : ('a, string) Field.t -> string -> 'a t
    val ends_with : ('a, string) Field.t -> string -> 'a t
    val contains : ('a, string) Field.t -> string -> 'a t

    val is_in : ('a, string) Field.t -> string list -> 'a t
    (** Comparisons use exact bytes, without case folding or normalization. The
        empty substring matches every string. *)
  end

  module Rel : sig
    val any : ('a, 'b) Relation.Many.t -> 'b t -> 'a t
    val all : ('a, 'b) Relation.Many.t -> 'b t -> 'a t

    val none : ('a, 'b) Relation.Many.t -> 'b t -> 'a t
    (** On empty relations, [any] is false; [all] and [none] are true. One child
        must satisfy the complete nested expression. *)

    val is : ('a, 'b) Relation.One.t -> 'b t -> 'a t
    val exists : ('a, 'b) Relation.Optional.t -> 'b t -> 'a t
    val is_absent : ('a, 'b) Relation.Optional.t -> 'a t
  end

  val compile : 'a t -> 'a -> bool
  (** Prepare a reusable predicate. Compilation and evaluation perform no I/O.
  *)

  val pp : Format.formatter -> 'a t -> unit
  val describe : 'a t -> string

  type _ comparison =
    | Bool_equal : bool -> bool comparison
    | Int_equal : int -> int comparison
    | Int_lt : int -> int comparison
    | Int_le : int -> int comparison
    | Int_gt : int -> int comparison
    | Int_ge : int -> int comparison
    | Int_in : int list -> int comparison
    | Text_equal : string -> string comparison
    | Text_starts_with : string -> string comparison
    | Text_ends_with : string -> string comparison
    | Text_contains : string -> string comparison
    | Text_in : string list -> string comparison

  type 'a view =
    | Compare : ('a, 'v) Field.t * 'v comparison -> 'a view
    | All of 'a t list
    | Any of 'a t list
    | Not of 'a t
    | Related_any : ('a, 'b) Relation.Many.t * 'b t -> 'a view
    | Related_all : ('a, 'b) Relation.Many.t * 'b t -> 'a view
    | Related_none : ('a, 'b) Relation.Many.t * 'b t -> 'a view
    | Related_one : ('a, 'b) Relation.One.t * 'b t -> 'a view
    | Related_optional : ('a, 'b) Relation.Optional.t * 'b t -> 'a view
    | Absent : ('a, 'b) Relation.Optional.t -> 'a view

  val view : 'a t -> 'a view
  (** Typed read-only inspection for codecs and planners. A view cannot add
      custom accessors or closures to an expression. *)
end

module Plan : sig
  type pushdown = Auto | Never | Require_exact
  type t

  val panes : ?pushdown:pushdown -> Pane.t Expr.t -> (t, Error.t) result
  (** Plan without I/O. Exact lowering covers pane active/dead flags and
      complete Boolean combinations. Unsupported children prevent lowering the
      whole expression, including under OR and NOT. Relationships always stay
      local. [Require_exact] rejects an unsupported expression before
      acquisition. *)

  val source_filter : t -> string option
  val residual : t -> Pane.t Expr.t
  val required_fields : t -> string list
  val required_relations : t -> string list
  val explanation : t -> string
  val pp : Format.formatter -> t -> unit
end

module Cardinality : sig
  type error = No_match | Multiple_matches of { at_least : int }

  val pp_error : Format.formatter -> error -> unit
end

module Query : sig
  val matching : 'a Expr.t -> 'a Seq.t -> 'a Seq.t
  (** [matching expression] compiles once when the adapter is constructed.
      Filtering preserves order and duplicates. Snapshot-derived sequences
      replay captured values; arbitrary input sequences retain their effects,
      exceptions and replay semantics. No tmux acquisition occurs. *)

  val exactly_one : 'a Seq.t -> ('a, Cardinality.error) result
  (** Return the unique value. Stop when a second value is found; proving
      uniqueness requires exhausting the remaining sequence. The input's effects
      and exceptions propagate. This does not execute a mutation. *)

  val one_or_none : 'a Seq.t -> ('a option, Cardinality.error) result
  (** As {!exactly_one}, with [Ok None] for an empty sequence. Order and
      duplicate entries count toward cardinality; values are not deduplicated.
  *)
end

module Captured_text : sig
  type t = {
    bytes : string;
    source : Source.t;
    pane : Pane.Id.t;
    started_at_ns : int64;
    finished_at_ns : int64;
  }
  (** Ordinary rendered rows captured over an interval. This value has no
      implied relationship to a subscription cursor. *)
end

module Key : sig
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

module Spawn : sig
  type command =
    | Default
    | Exec of { program : string; args : string list }
    | Shell of string

  type t = {
    command : command;
    cwd : string option;
    environment : (string * string) list;
  }

  val make : ?cwd:string -> ?environment:(string * string) list -> command -> t
  (** Describe a program without I/O. [Exec] preserves argv; [Shell] explicitly
      requests the daemon's configured shell. [cwd] must be absolute. Validation
      occurs at admission. With no arguments, [Exec] uses a fixed [/bin/sh]
      trampoline because tmux treats a single argument as shell code. [Default]
      follows tmux defaults on creation and reuses the previous command on
      respawn. *)

  val default : t
end

module Geometry : sig
  type direction = Left | Right | Above | Below
  type size = Cells of int | Percent of int
end

module Layout : sig
  type t =
    | Even_horizontal
    | Even_vertical
    | Main_horizontal
    | Main_vertical
    | Tiled
    | Custom of string
end

module Created : sig
  type t = {
    session : Session.target;
    window : Window.target;
    pane : Pane.target;
    window_index : int;
    pane_index : int;
  }
  (** IDs returned by the creation command, without a second capture. Indexes
      describe the creation response and may change afterward. Only the resource
      requested by the command is newly created: splitting a pane does not
      create the reported session or window. *)
end

module Environment : sig
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
  (** One captured environment table, in tmux order. [hidden] selects hidden
      variables exclusively. Session tables contain local entries, including
      removal markers; they do not merge the global environment. *)

  val lookup : t -> string -> value option
  (** No I/O. [None] means absent from the selected table and visibility.
      [Removed] masks a global value; [Value ""] is an explicitly empty value.
      Names must be ASCII identifiers; values preserve non-NUL bytes. *)
end

module Options : sig
  module Kind : sig
    type t = Text | Number | Flag | Choice | Key | Colour | Commands
  end

  type descriptor = {
    name : string;
    kind : Kind.t;
    array : bool;
    hook : bool;
    scopes : [ `Server | `Session | `Window | `Pane ] list;
    versions : string list;
  }
  (** Generated upstream descriptors. [versions] lists qualified releases; user
      options have no built-in release history. *)

  type scope =
    | Server
    | Global_sessions
    | Global_windows
    | Session of Session.target
    | Window of Window.target
    | Pane of Pane.target

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
    source : Source.t;
    scope : scope;
    include_inherited : bool;
    entries : entry Iarray.t;
    started_at_ns : int64;
    finished_at_ns : int64;
  }
  (** Captured options in tmux order, with original array indexes. An empty
      array differs from an absent local entry. No accessor performs I/O. *)

  val catalog : version:string -> (descriptor Iarray.t, Error.t) result
  val describe : version:string -> string -> (descriptor, Error.t) result

  val lookup : t -> string -> entry option
  (** [None] means absent from this capture's selected scope and inheritance
      policy. Use [describe] to distinguish an unsupported built-in name. *)
end

module Hook : sig
  type command = { name : string; arguments : string list }
  (** A tmux command and its distinct arguments. Setting a hook encodes these as
      command data; it does not concatenate arguments into shell code.
      Argument-specific tmux behavior, including format expansion, still applies
      when the hook runs. *)
end

module Command : sig
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

  type 'a t
  (** An immutable description, validated by a backend before admission.
      Constructing or inspecting it performs no I/O. *)

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

  val view : 'a t -> 'a view
  (** Read-only inspection for transport adapters. *)
end

module Output : sig
  type cursor = { generation : Generation.t; offset : int64 }
  (** [offset] is the number of observed bytes through the end of a Data event.
      Cursors from different subscription generations are unrelated. No cursor
      identifies a snapshot instant or a server-side historical position. *)

  type reason =
    | Overflow
    | Membership_changed
    | Server_paused
    | Cancelled
    | Client_closed
    | Transport_error of Error.t

  type event =
    | Data of { cursor : cursor; bytes : string }
    | Gap of { after : cursor option; lost_bytes : int option; reason : reason }
    | End of reason
        (** Immutable event values. [Gap.after] is the last cursor delivered to
            the caller. Unknown loss is [None]. A gap ends continuity and is
            followed by End; recover with a fresh capture and a new
            subscription. Data preserves bytes, including NUL and invalid UTF-8.
            It is future observed output, not rendered text or historical
            reconstruction. *)

  val reason_pp : Format.formatter -> reason -> unit

  type wait_error =
    | Ended of reason
    | Failure of Error.t
        (** A future-byte wait either loses its subscription's continuity or
            fails an operation. Neither result establishes that the text was
            absent earlier. *)
end

module Operations : sig
  val capture : unit -> Snapshot.t Command.t

  val capture_text :
    ?scratch_dir:string ->
    Pane.t ->
    start:int ->
    end_:int ->
    Captured_text.t Command.t

  val rename_window : Window.target -> name:string -> unit Command.t
  val rename_session : Session.target -> name:string -> unit Command.t

  val switch_client_at :
    ?update_environment:bool ->
    Client_name.t ->
    session:Session.target ->
    unit Command.t
  (** Switch the client currently bearing this name to the bound session.
      Environment updates are disabled by default. This can move either a
      terminal client or a control client; it does not open a new terminal. *)

  val request_detach_client_at : Client_name.t -> unit Command.t
  (** Request detachment of the client currently bearing this name. Success
      confirms request processing, not peer exit. Detaching the library's own
      primary lane can lose the response and retire its generation. *)

  val refresh_client_at : ?status_only:bool -> Client_name.t -> unit Command.t
  (** Request a redraw; no terminal-rendering completion is implied. *)

  val resize_control_client_at :
    Client_name.t -> width:int -> height:int -> unit Command.t
  (** Set a control client's reported size. tmux rejects terminal clients. *)

  val send_text : Pane.target -> text:string -> unit Command.t
  (** Literal bytes, without an implicit Enter. NUL is rejected at admission. *)

  val send_keys : Pane.target -> Key.t list -> unit Command.t

  val wait_for : string -> unit Command.t
  (** Wait on a named tmux semaphore using a dedicated bound lane. *)

  val signal : string -> unit Command.t

  val capture_environment :
    ?hidden:bool -> Environment.scope -> Environment.t Command.t
  (** Acquire a bounded table through a read-only command process. Its response
      must identify the bound daemon while the original pidfd remains live.
      Unsupported external variable names fail decoding; they are not omitted.
  *)

  val set_environment :
    ?hidden:bool -> Environment.scope -> name:string -> string -> unit Command.t

  val unset_environment : Environment.scope -> string -> unit Command.t
  (** Remove the local entry, allowing a global value to apply to future panes.
  *)

  val remove_environment : Environment.scope -> string -> unit Command.t
  (** Store a removal marker, excluding the variable from future panes. *)

  val capture_options :
    ?include_inherited:bool -> Options.scope -> Options.t Command.t
  (** Acquire one bounded option table, excluding hooks. The default includes
      only local entries. Inherited table enumeration includes built-ins;
      inherited user options require [read_option] with their explicit name.
      Built-in descriptors are qualified on tmux 3.3, 3.3a, 3.4 and 3.8; other
      versions return [Unsupported]. *)

  val read_option :
    ?include_inherited:bool ->
    Options.scope ->
    string ->
    Options.value option Command.t
  (** Read one exact name, including user-option inheritance. [None] means no
      entry under the selected policy. An invalid target remains an error. The
      default follows inheritance; this does not identify the defining parent
      scope. *)

  val set_option :
    ?index:int ->
    ?append:bool ->
    Options.scope ->
    name:string ->
    Options.scalar ->
    unit Command.t
  (** Validate the scope and scalar kind before admission. Array values require
      an index, or [append:true]. Without an index, tmux splits appended text
      using the option's separator and fills the lowest unused indexes. Text is
      literal; tmux format expansion is disabled. Hooks use a separate
      operation. *)

  val unset_option : ?index:int -> Options.scope -> string -> unit Command.t
  (** Remove a local override or one array element. Global built-ins reset to
      their tmux defaults; this does not recursively unset child overrides. *)

  val clear_option_array : Options.scope -> string -> unit Command.t
  (** Set a local empty array, masking inheritance. *)

  val capture_hooks : Options.scope -> Options.t Command.t
  (** Capture locally configured built-in hooks. Command values are tmux's
      printed representation, retained as data. *)

  val read_hook :
    ?include_inherited:bool ->
    Options.scope ->
    string ->
    Options.value option Command.t

  val set_hook :
    ?index:int ->
    ?append:bool ->
    Options.scope ->
    name:string ->
    Hook.command list ->
    unit Command.t
  (** Set a hook to a nonempty command list. Without an index, replace the whole
      hook array, or fill the lowest free index when appending. An explicit
      [@name] custom hook stores command text as a user option; it requires
      complete replacement and has no array indexes. [read_hook] returns its
      [Options.Text] value; bulk hook capture includes built-ins. Commands may
      cause arbitrary tmux effects when triggered. Hooks that print output are
      outside the supported control transport contract. *)

  val remove_hook : ?index:int -> Options.scope -> string -> unit Command.t

  val run_hook : Options.scope -> string -> unit Command.t
  (** Run the effective hook in an explicit session, window or pane context. A
      successful result follows completion of its synchronous command queue.
      Background work started by a hook has its own lifetime. A later hook
      failure returns an uncertain outcome; preceding effects remain. Named [@]
      hooks return [Unsupported] because tmux can hide their parse failures in
      the server log. Configuration and inspection remain available. *)

  val create_session :
    ?window_name:string ->
    ?width:int ->
    ?height:int ->
    ?spawn:Spawn.t ->
    name:string ->
    unit ->
    Created.t Command.t
  (** Create a detached session on the bound daemon. Name collisions fail. *)

  val create_window :
    ?index:int ->
    ?name:string ->
    ?spawn:Spawn.t ->
    Session.target ->
    Created.t Command.t
  (** Create detached, rejecting an occupied explicit index. *)

  val split_pane :
    ?size:Geometry.size ->
    ?spawn:Spawn.t ->
    Pane.target ->
    direction:Geometry.direction ->
    Created.t Command.t

  val break_pane :
    ?name:string ->
    Pane.target ->
    session:Session.target ->
    index:int ->
    Created.t Command.t

  val kill_session : Session.target -> unit Command.t
  val kill_window : Window.target -> unit Command.t
  val kill_pane : Pane.target -> unit Command.t

  val select_window_at : Session.target -> index:int -> unit Command.t
  (** Operate on the session's current index at execution, not an old link
      incarnation. *)

  val unlink_window_at :
    ?allow_kill:bool -> Session.target -> index:int -> unit Command.t
  (** Without [allow_kill], tmux rejects removal of the last link to a window.
  *)

  val link_window :
    Window.target -> session:Session.target -> index:int -> unit Command.t

  val move_window_at :
    Session.target ->
    from_index:int ->
    session:Session.target ->
    index:int ->
    unit Command.t
  (** Move the source session's current link at [from_index]. Destination
      collisions fail. *)

  val select_pane : Pane.target -> unit Command.t
  val set_pane_title : Pane.target -> title:string -> unit Command.t
  val resize_pane : ?width:int -> ?height:int -> Pane.target -> unit Command.t

  val resize_window :
    ?width:int -> ?height:int -> Window.target -> unit Command.t

  val select_layout : Window.target -> Layout.t -> unit Command.t
  val cycle_layout : Window.target -> [ `Next | `Previous ] -> unit Command.t

  val move_pane :
    ?size:Geometry.size ->
    Pane.target ->
    beside:Pane.target ->
    direction:Geometry.direction ->
    unit Command.t

  val swap_panes : Pane.target -> Pane.target -> unit Command.t
  val rotate_panes : Window.target -> [ `Forward | `Backward ] -> unit Command.t

  val zoom_pane : Pane.target -> unit Command.t
  (** Toggle the window's zoom state around this pane. *)

  val respawn_pane :
    ?kill_running:bool -> Pane.target -> Spawn.t -> unit Command.t

  val clear_history : Pane.target -> unit Command.t
end
