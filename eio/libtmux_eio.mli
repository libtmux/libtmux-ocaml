(** Concurrent Linux tmux clients using the application's Eio scheduler.

    Client methods perform I/O unless documented otherwise. Captured
    {!Libtmux.Snapshot} observations and retained {!Operation.inspect} remain
    local. Clients belong to the connecting domain. Closure releases their owned
    resources; tmux applies its configured daemon lifetime.

    See {!Client} for acquisition and commands, {!Operation} for cancellation
    outcomes, and {!Subscription} for bounded future output. The
    {{:https://github.com/libtmux/libtmux-ocaml/blob/master/docs/streaming.md}streaming
     guide} demonstrates application-owned switches, cancellation and continuity
    gaps. *)

module Rendered = Libtmux.Captured_text

(** Interactive attachment using borrowed application streams. This utility
    addresses the current daemon explicitly and does not reuse captured targets.
*)
module Terminal : sig
  val attach_current :
    ?binary:string ->
    ?read_only:bool ->
    ?update_environment:bool ->
    ?stdin:_ Eio.Flow.source ->
    ?stdout:_ Eio.Flow.sink ->
    ?stderr:_ Eio.Flow.sink ->
    process_mgr:_ Eio.Process.mgr ->
    Libtmux.Endpoint.t ->
    session:Libtmux.Session.Id.t ->
    (unit, Libtmux.Error.t) result
  (** Run an interactive terminal client until exit, using the application's
      process manager and standard streams unless explicit flows are supplied.
      [stdin] must be backed by a terminal descriptor; a pipe-backed flow is
      rejected by tmux. Select the exact ID on the daemon currently listening at
      [endpoint], without a captured target, binding, retry or daemon startup.

      Environment updates and read-only mode default to false. Clear inherited
      [TMUX] and [TMUX_PANE]. Cancellation propagates after terminating and
      reaping this client; it does not stop the daemon. Cooperative TERM gets
      200 ms of grace before forced termination, while other fibers can run.
      Scheduling and kernel completion can add time. Success proves terminal
      client exit. Diagnostics go to [stderr]; borrowed flows stay open. *)
end

(** A retained admitted command. A cancelled waiter does not erase its eventual
    success, failure or uncertainty. *)
module Operation : sig
  type 'a t

  type cleanup_receipt = {
    cause : Libtmux.Error.t;
    owned_buffers : string list;
    created : Libtmux.Created.t list;
  }
  (** [created] retains IDs reported before a later hook or completion failure.
      It does not prove those resources still exist or authorize retry. *)

  type 'a state =
    | Queued
    | Not_started
    | Written
    | Acknowledged
    | Finished of ('a, Libtmux.Error.t) result
    | Outcome_unknown of cleanup_receipt

  val id : 'a t -> string

  val inspect : 'a t -> ('a state, Libtmux.Error.t) result
  (** Read without I/O, including after client closure. Owning domain only. *)

  val cancel : 'a t -> (unit, Libtmux.Error.t) result
  (** Remove unsent work. A written request remains owned and drained by the
      client. *)

  val await_stage :
    'a t -> [ `Written | `Acknowledged ] -> ('a state, Libtmux.Error.t) result
  (** Wait for the named stage or a terminal state. Acknowledgement does not
      establish completion. Cancelling this observer leaves the operation alone.
  *)
end

(** Bounded future-byte observation with Data/Gap/End and local cursors. Polling
    is local; waiting and admission belong to the backend. *)
module Subscription : sig
  type t

  val poll : t -> (Libtmux.Output.event option, Libtmux.Error.t) result
  (** Remove a queued event without I/O, on the owning domain. *)

  val next :
    ?timeout:float -> t -> (Libtmux.Output.event option, Libtmux.Error.t) result
  (** Await one event, defaulting to a one-second deadline. [None] follows a
      consumed End. A deadline keeps the subscription active. Eio cancellation
      closes it, releases its lane when unused, and propagates. *)

  val close : t -> (unit, Libtmux.Error.t) result
  (** Discard pending data and retain End Cancelled. Borrowed clients and the
      daemon remain alive. *)

  val wait_for_bytes :
    ?timeout:float ->
    t ->
    text:string ->
    (Libtmux.Output.cursor, Libtmux.Output.wait_error) result
  (** Consume future observed bytes through a match, with a maximum 64 KiB
      nonempty pattern. Match across Data boundaries and return its end cursor.
      Gaps end matching. This searches neither rendered text nor history. A
      deadline leaves the subscription active; cancellation closes it. *)
end

(** An explicit generation-bound connection. Applications retain ownership of
    the endpoint choice and resource lifetime. *)
module Client : sig
  type t

  val connect :
    ?binary:string ->
    ?timeout:float ->
    sw:Eio.Switch.t ->
    process_mgr:_ Eio.Process.mgr ->
    mono_clock:_ Eio.Time.Mono.t ->
    Libtmux.Endpoint.t ->
    (t, Libtmux.Error.t) result
  (** Attach to an existing local Linux daemon in the same PID namespace and
      shared filesystem. Requires pidfd support. Default exchange timeout: one
      second. All client calls belong to the connecting OCaml domain. Initial
      and auxiliary attachments suppress tmux's [update-environment] behavior.
  *)

  val source : t -> Libtmux.Source.t
  (** Read the retained endpoint, daemon PID and connection generation without
      I/O. *)

  val version : t -> string
  (** Read the bound daemon's observed version without I/O. *)

  val subscribe :
    ?session:Libtmux.Session.target ->
    ?capacity_bytes:int ->
    ?capacity_events:int ->
    t ->
    Libtmux.Pane.t ->
    (Subscription.t, Libtmux.Error.t) result
  (** Acquire verified coverage through one shared lane per session; choose the
      least observed session ID unless supplied. A client-owned reader delivers
      future bytes without application callbacks. Default queue bounds are 1
      MiB/1024 events; max 16 subscribers and eight total client lanes, sharing
      the 32 MiB payload budget. Overflow or coverage/layout changes emit Gap
      then End. Data starts after admission's marker, with no snapshot/history
      barrier, automatic reconnect or silent cursor reuse. *)

  val wait_for_text :
    ?timeout:float ->
    ?scratch_dir:string ->
    t ->
    Libtmux.Pane.t ->
    text:string ->
    (Rendered.t, Libtmux.Error.t) result
  (** Subscribe and capture the screen immediately, then recapture on output.
      Membership/overflow gaps establish fresh coverage in the same binding.
      Maximum pattern: 64 KiB. Return captured rendered text containing it;
      transient text may be missed. Deadlines are checked between bounded
      acquisitions, whose I/O retains the client exchange timeout. Cancellation
      propagates and releases the subscription. No history/barrier guarantee. *)

  val submit :
    t -> 'a Libtmux.Command.t -> ('a Operation.t, Libtmux.Error.t) result
  (** Validate and reserve bounded capacity without I/O. *)

  val await : 'a Operation.t -> ('a, Libtmux.Error.t) result
  (** Cancellation propagates as Eio cancellation. Store the handle outside the
      cancelled fiber: the client drains written work independently, and the
      eventual result remains inspectable. *)

  val run : t -> 'a Libtmux.Command.t -> ('a, Libtmux.Error.t) result
  (** Submit and await an explicit command. Retain a separate submitted handle
      when the outcome must remain inspectable after caller cancellation. *)

  val capture : t -> (Libtmux.Snapshot.t, Libtmux.Error.t) result
  (** Acquire a complete immutable graph over an interval. Conflicting or
      disappearing entities fail capture; they do not become empty relations.
      The returned values remain readable after client closure. *)

  val capture_text :
    ?scratch_dir:string ->
    t ->
    Libtmux.Pane.t ->
    start:int ->
    end_:int ->
    (Rendered.t, Libtmux.Error.t) result
  (** Inclusive ordinary screen rows, using a bounded private file transfer.
      Qualified local scratch storage must be shared with the daemon. *)

  (* BEGIN GENERATED OPERATIONS *)
  val rename_window :
    t -> Libtmux.Window.target -> name:string -> (unit, Libtmux.Error.t) result
  (** Set the global window name. Every session link observes the new name on
      its next capture; existing snapshots retain the old value. *)

  val rename_session :
    t -> Libtmux.Session.target -> name:string -> (unit, Libtmux.Error.t) result
  (** Set the session name, rejecting a conflicting existing name. Bound IDs
      remain usable; existing snapshots retain their captured names. *)

  val switch_client_at :
    ?update_environment:bool ->
    t ->
    Libtmux.Client_name.t ->
    session:Libtmux.Session.target ->
    (unit, Libtmux.Error.t) result
  (** Switch the client currently bearing this name to the bound session.
      Environment updates are disabled by default. This can move either a
      terminal client or a control client; it does not open a new terminal. *)

  val request_detach_client_at :
    t -> Libtmux.Client_name.t -> (unit, Libtmux.Error.t) result
  (** Request detachment of the client currently bearing this name. Success
      confirms request processing, not peer exit. Detaching the library's own
      primary lane can lose the response and retire its generation. *)

  val refresh_client_at :
    ?status_only:bool ->
    t ->
    Libtmux.Client_name.t ->
    (unit, Libtmux.Error.t) result
  (** Request a redraw; no terminal-rendering completion is implied. *)

  val resize_control_client_at :
    t ->
    Libtmux.Client_name.t ->
    width:int ->
    height:int ->
    (unit, Libtmux.Error.t) result
  (** Set a control client's reported size. tmux rejects terminal clients. *)

  val send_text :
    t -> Libtmux.Pane.target -> text:string -> (unit, Libtmux.Error.t) result
  (** Literal bytes, without an implicit Enter. NUL is rejected at admission. *)

  val send_keys :
    t ->
    Libtmux.Pane.target ->
    Libtmux.Key.t list ->
    (unit, Libtmux.Error.t) result
  (** Send named tmux keys in order, without an implicit Enter. Use {!send_text}
      for literal bytes rather than key interpretation. *)

  val wait_for : t -> string -> (unit, Libtmux.Error.t) result
  (** Wait on a named tmux semaphore using a dedicated bound lane. *)

  val signal : t -> string -> (unit, Libtmux.Error.t) result
  (** Signal a named tmux semaphore, releasing a waiter or retaining the signal
      for a later {!wait_for}. This does not signal an OS process. *)

  val capture_environment :
    ?hidden:bool ->
    t ->
    Libtmux.Environment.scope ->
    (Libtmux.Environment.t, Libtmux.Error.t) result
  (** Acquire a bounded table through a read-only command process. Its response
      must identify the bound daemon while the original pidfd remains live.
      Unsupported external variable names fail decoding; they are not omitted.
  *)

  val set_environment :
    ?hidden:bool ->
    t ->
    Libtmux.Environment.scope ->
    name:string ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Set a local environment value for future pane processes. [hidden] defaults
      to false; hidden values remain internal to tmux. Existing processes keep
      their environment. *)

  val unset_environment :
    t -> Libtmux.Environment.scope -> string -> (unit, Libtmux.Error.t) result
  (** Remove the local entry, allowing a global value to apply to future panes.
  *)

  val remove_environment :
    t -> Libtmux.Environment.scope -> string -> (unit, Libtmux.Error.t) result
  (** Store a removal marker, excluding the variable from future panes. *)

  val capture_options :
    ?include_inherited:bool ->
    t ->
    Libtmux.Options.scope ->
    (Libtmux.Options.t, Libtmux.Error.t) result
  (** Acquire one bounded option table, excluding hooks. The default includes
      only local entries. Inherited table enumeration includes built-ins;
      inherited user options require [read_option] with their explicit name.
      Built-in descriptors are qualified on tmux 3.3, 3.3a, 3.4 and 3.8; other
      versions return [Unsupported]. *)

  val read_option :
    ?include_inherited:bool ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (Libtmux.Options.value option, Libtmux.Error.t) result
  (** Read one exact name, including user-option inheritance. [None] means no
      entry under the selected policy. An invalid target remains an error. The
      default follows inheritance; this does not identify the defining parent
      scope. *)

  val set_option :
    ?index:int ->
    ?append:bool ->
    t ->
    Libtmux.Options.scope ->
    name:string ->
    Libtmux.Options.scalar ->
    (unit, Libtmux.Error.t) result
  (** Validate the scope and scalar kind before admission. Array values require
      an index, or [append:true]. Without an index, tmux splits appended text
      using the option's separator and fills the lowest unused indexes. Text is
      literal; tmux format expansion is disabled. Hooks use a separate
      operation. *)

  val unset_option :
    ?index:int ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Remove a local override or one array element. Global built-ins reset to
      their tmux defaults; this does not recursively unset child overrides. *)

  val clear_option_array :
    t -> Libtmux.Options.scope -> string -> (unit, Libtmux.Error.t) result
  (** Set a local empty array, masking inheritance. *)

  val capture_hooks :
    t -> Libtmux.Options.scope -> (Libtmux.Options.t, Libtmux.Error.t) result
  (** Capture locally configured built-in hooks. Command values are tmux's
      printed representation, retained as data. *)

  val read_hook :
    ?include_inherited:bool ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (Libtmux.Options.value option, Libtmux.Error.t) result
  (** Read an exact hook name. Inheritance is included by default; [None] means
      no entry under the selected policy. Missing targets remain errors. *)

  val set_hook :
    ?index:int ->
    ?append:bool ->
    t ->
    Libtmux.Options.scope ->
    name:string ->
    Libtmux.Hook.command list ->
    (unit, Libtmux.Error.t) result
  (** Set a hook to a nonempty command list. Without an index, replace the whole
      hook array, or fill the lowest free index when appending. An explicit
      [@name] custom hook stores command text as a user option; it requires
      complete replacement and has no array indexes. [read_hook] returns its
      [Libtmux.Options.Text] value; bulk hook capture includes built-ins.
      Commands may cause arbitrary tmux effects when triggered. Hooks that print
      output are outside the supported control transport contract. *)

  val remove_hook :
    ?index:int ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Remove the local hook or one indexed array entry. An inherited hook may
      become effective again; this does not stop work it already started. *)

  val run_hook :
    t -> Libtmux.Options.scope -> string -> (unit, Libtmux.Error.t) result
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
    ?spawn:Libtmux.Spawn.t ->
    t ->
    name:string ->
    unit ->
    (Libtmux.Created.t, Libtmux.Error.t) result
  (** Create a detached session on the bound daemon. Name collisions fail. *)

  val create_window :
    ?index:int ->
    ?name:string ->
    ?spawn:Libtmux.Spawn.t ->
    t ->
    Libtmux.Session.target ->
    (Libtmux.Created.t, Libtmux.Error.t) result
  (** Create detached, rejecting an occupied explicit index. *)

  val split_pane :
    ?size:Libtmux.Geometry.size ->
    ?spawn:Libtmux.Spawn.t ->
    t ->
    Libtmux.Pane.target ->
    direction:Libtmux.Geometry.direction ->
    (Libtmux.Created.t, Libtmux.Error.t) result
  (** Create a detached pane beside the target and return the IDs reported by
      tmux. Omitted [size] lets tmux choose the split; tmux rejects splits when
      no space remains. *)

  val break_pane :
    ?name:string ->
    t ->
    Libtmux.Pane.target ->
    session:Libtmux.Session.target ->
    index:int ->
    (Libtmux.Created.t, Libtmux.Error.t) result
  (** Move the pane into a new window at an explicit session index. An occupied
      destination fails. The returned IDs describe the resulting context; the
      pane itself already existed. *)

  val kill_session :
    t -> Libtmux.Session.target -> (unit, Libtmux.Error.t) result
  (** Remove the session and its window links. Windows with no other links and
      their panes are destroyed. Removing the last session may stop tmux. *)

  val kill_window : t -> Libtmux.Window.target -> (unit, Libtmux.Error.t) result
  (** Destroy the window, all its session links and every contained pane. This
      acts on the global window, not a single contextual link. *)

  val kill_pane : t -> Libtmux.Pane.target -> (unit, Libtmux.Error.t) result
  (** Destroy the target pane and its running process. tmux removes a window
      that becomes empty and may remove its now-empty sessions. *)

  val select_window_at :
    t -> Libtmux.Session.target -> index:int -> (unit, Libtmux.Error.t) result
  (** Operate on the session's current index at execution, not an old link
      incarnation. *)

  val unlink_window_at :
    ?allow_kill:bool ->
    t ->
    Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Without [allow_kill], tmux rejects removal of the last link to a window.
  *)

  val link_window :
    t ->
    Libtmux.Window.target ->
    session:Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Add a session-specific link to the global window at [index], rejecting an
      occupied index. The source window and its panes stay shared. *)

  val move_window_at :
    t ->
    Libtmux.Session.target ->
    from_index:int ->
    session:Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Move the source session's current link at [from_index]. Destination
      collisions fail. *)

  val select_pane : t -> Libtmux.Pane.target -> (unit, Libtmux.Error.t) result
  (** Make the pane active in its containing window. This does not open or
      attach a terminal client. *)

  val set_pane_title :
    t -> Libtmux.Pane.target -> title:string -> (unit, Libtmux.Error.t) result
  (** Set the pane title as literal text, without tmux format expansion. A
      running terminal application can subsequently replace the title. *)

  val resize_pane :
    ?width:int ->
    ?height:int ->
    t ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Request positive cell dimensions, supplying at least one dimension. Omit
      either dimension to retain it. tmux can constrain the result to the
      available layout. Capture again to observe the actual dimensions. *)

  val resize_window :
    ?width:int ->
    ?height:int ->
    t ->
    Libtmux.Window.target ->
    (unit, Libtmux.Error.t) result
  (** Request positive cell dimensions, supplying at least one dimension. Omit
      either dimension to retain it. Client-size and window-size policies can
      affect subsequent sizing. *)

  val select_layout :
    t ->
    Libtmux.Window.target ->
    Libtmux.Layout.t ->
    (unit, Libtmux.Error.t) result
  (** Apply a preset or validated custom layout to the window. Pane geometry
      follows tmux layout rules; capture again to observe the result. *)

  val cycle_layout :
    t ->
    Libtmux.Window.target ->
    [ `Next | `Previous ] ->
    (unit, Libtmux.Error.t) result
  (** Select the next or previous tmux preset layout for this window. *)

  val move_pane :
    ?size:Libtmux.Geometry.size ->
    t ->
    Libtmux.Pane.target ->
    beside:Libtmux.Pane.target ->
    direction:Libtmux.Geometry.direction ->
    (unit, Libtmux.Error.t) result
  (** Move the source pane beside another pane, optionally setting the split
      size. Both targets must belong to the same bound generation. An emptied
      source window is removed by tmux. *)

  val swap_panes :
    t ->
    Libtmux.Pane.target ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Exchange pane positions without exchanging their identities or running
      processes. Both targets must belong to the same bound generation. *)

  val rotate_panes :
    t ->
    Libtmux.Window.target ->
    [ `Forward | `Backward ] ->
    (unit, Libtmux.Error.t) result
  (** Rotate pane positions in the selected direction. Pane identities and
      running processes remain attached to their panes. *)

  val zoom_pane : t -> Libtmux.Pane.target -> (unit, Libtmux.Error.t) result
  (** Toggle the window's zoom state around this pane. *)

  val respawn_pane :
    ?kill_running:bool ->
    t ->
    Libtmux.Pane.target ->
    Libtmux.Spawn.t ->
    (unit, Libtmux.Error.t) result
  (** Start the supplied command in the existing pane. A running process causes
      failure unless [kill_running:true] explicitly replaces it. The pane ID
      remains unchanged. *)

  val clear_history : t -> Libtmux.Pane.target -> (unit, Libtmux.Error.t) result
  (** Clear stored scrollback for this pane. The visible screen and running
      process remain; later captures cannot recover discarded history. *)

  (* END GENERATED OPERATIONS *)

  val close : t -> (unit, Libtmux.Error.t) result
  (** Retire the generation and close owned control clients and descriptors.
      Each helper gets 200 ms of TERM grace, followed by KILL if needed and
      reaping. Other fibers can run during that wait. The grace is per helper;
      it does not bound scheduling, filesystem or uninterruptible kernel work.
      No signal targets the daemon. tmux's [exit-unattached] and [exit-empty]
      policies can end the daemon after its clients or sessions disappear. *)
end

(** Apply workspace plans through Eio while retaining journals across caller
    cancellation. Handles belong to the creating domain; the application owns
    the scheduler and switch. *)
module Workspace : sig
  type t

  val submit :
    Client.t -> Libtmux_workspace.Plan.t -> (t, Libtmux.Error.t) result
  (** Allocate a generation-bound handle without I/O. The supplied client is
      borrowed; closing the handle leaves it open. *)

  val submit_bootstrap :
    ?binary:string ->
    ?timeout:float ->
    sw:Eio.Switch.t ->
    process_mgr:_ Eio.Process.mgr ->
    mono_clock:_ Eio.Time.Mono.t ->
    Libtmux_workspace.Plan.t ->
    (t, Libtmux.Error.t) result
  (** Allocate a missing-endpoint execution without I/O. Await starts control
      new-session and binds that same connection. The handle owns its new client
      within [sw]; it never owns the daemon. *)

  val await :
    ?compensate_on_failure:bool ->
    t ->
    (Libtmux_workspace.Execution.receipt, Libtmux.Error.t) result
  (** Apply once. Expected failures return a retained journal. Eio cancellation
      propagates after progress is recorded and at most 500 ms of protected
      compensation. Admitted commands can still complete under client ownership;
      inspect the receipt before attempting manual recovery. *)

  val inspect :
    t -> (Libtmux_workspace.Execution.receipt, Libtmux.Error.t) result
  (** Read a journal copy without I/O, including any late retained outcome. *)

  val client : t -> Client.t option
  (** Borrow the existing or bootstrapped {!Client.t} without I/O for subsequent
      actions or recovery. {!close} releases a client owned by this workspace
      execution handle. *)

  val close : t -> (unit, Libtmux.Error.t) result
  (** Release an owned client through {!Client.close}. Active await returns
      Busy. Closing is idempotent; completed journals remain readable. *)
end
