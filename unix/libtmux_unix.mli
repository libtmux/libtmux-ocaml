(** Blocking Linux tmux clients with explicit scoped cancellation.

    Client methods perform I/O unless documented otherwise. Captured
    {!Libtmux.Snapshot} observations and retained {!Operation.inspect} remain
    local. Clients belong to the connecting domain. Closure releases their owned
    resources; tmux applies its configured daemon lifetime.

    See {!Client} for acquisition and commands, {!Operation} for cancellation
    outcomes, and {!Subscription} for bounded future output. The
    {{:https://github.com/libtmux/libtmux-ocaml/blob/master/docs/control.md}control
     guide} explains binding, completion and recovery. *)

(** Retained failures from releasing processes and descriptors. Reports belong
    to their creating domain and remain readable after client closure. They
    preserve secondary failures without replacing a primary exception or
    cancellation. *)
module Cleanup : sig
  type t = Cleanup.t

  type phase = Cleanup.phase =
    | Close_pipe
    | Open_pidfd
    | Close_pidfd
    | Terminate
    | Grace
    | Kill
    | Reap
    | Unreaped_child
    | Cancel_workers
    | Release_hook
    | Notify_waiters

  type issue = Cleanup.issue = {
    phase : phase;
    error : Libtmux.Error.t option;
    exception_ : exn;
    backtrace : Printexc.raw_backtrace;
  }
  (** One failed cleanup action. [error] retains a typed library cause when
      available; [exception_] and [backtrace] retain the original exception.
      [Unreaped_child] means exit was not established after a failed signal. It
      does not release ownership or authorize signalling a reused PID. *)

  type snapshot = Cleanup.snapshot = { issues : issue Iarray.t; omitted : int }
  (** Issues in occurrence order, with a count of additional omitted issues. A
      report retains at most 64 entries. This bounds entry count, not heap
      retention: exception payloads and backtraces may retain other values.
      These diagnostics are not immutable graph observations. *)

  val create : unit -> t
  (** Create an empty report without I/O. Supply it before {!Client.connect},
      {!Workspace.submit_bootstrap} or {!Terminal.attach_current} to retain
      cleanup evidence even when setup fails or cancellation raises. *)

  val inspect : t -> (snapshot, Libtmux.Error.t) result
  (** Copy the current diagnostics without I/O. Returns
      {!Libtmux.Error.Wrong_domain} outside the creating domain. *)
end

module Rendered = Libtmux.Captured_text
(** Blocking native Linux transport. No Eio scheduler is started. *)

module Cancellation : sig
  type t

  exception Cancelled

  val with_ : (t -> 'a) -> 'a
  (** Own a cancellation token for the callback's lifetime. Leaving the scope
      cancels outstanding waiters and releases its descriptors after they
      finish. An escaped token is cancelled and cannot be reused. *)

  val cancel : t -> unit
  (** Wake waiters. Safe from another domain or systhread, but not from a signal
      handler. Repeated calls and calls after scope exit have no effect. *)
end

(** Interactive attachment using borrowed application streams. This utility
    addresses the current daemon explicitly and does not reuse captured targets.
*)
module Terminal : sig
  val attach_current :
    ?cancel:Cancellation.t ->
    ?cleanup:Cleanup.t ->
    ?binary:string ->
    ?read_only:bool ->
    ?update_environment:bool ->
    ?stdin:Unix.file_descr ->
    ?stdout:Unix.file_descr ->
    ?stderr:Unix.file_descr ->
    Libtmux.Endpoint.t ->
    session:Libtmux.Session.Id.t ->
    (unit, Libtmux.Error.t) result
  (** Run an interactive terminal client until it exits. Select the exact
      session ID on the daemon currently listening at [endpoint]; this is
      explicitly unbound and accepts no captured target. No retry or daemon
      startup occurs. A successful result proves client exit, not continued
      attachment. Diagnostics go to [stderr].

      Descriptors default to the application's standard streams and remain
      caller-owned. [stdin] must be a terminal. Environment updates and
      read-only mode are disabled by default; inherited [TMUX] and [TMUX_PANE]
      are removed. Cancellation terminates and reaps this terminal client,
      leaves the daemon running, then raises {!Cancellation.Cancelled}. TERM
      gets 200 ms of cooperative grace before KILL and reaping. Scheduling and
      uninterruptible kernel work can add time. Supply [cleanup] before the call
      to retain secondary failures after cancellation. *)
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
  (** No I/O. Results remain inspectable after client closure, on the owning
      domain. *)

  val cancel : 'a t -> (unit, Libtmux.Error.t) result
  (** Remove queued work before it is written. Admitted commands retain their
      owner and are drained by {!Client.await}; cancellation does not undo
      effects. Returns [Busy] while another blocking caller owns the client; use
      a {!Cancellation.t} token to interrupt that caller. *)
end

(** Bounded future-byte observation with Data/Gap/End and local cursors. Polling
    is local; waiting and admission belong to the backend. *)
module Subscription : sig
  type t

  val poll : t -> (Libtmux.Output.event option, Libtmux.Error.t) result
  (** Remove a queued event without I/O. Owning domain only, including after
      client closure. [None] means no queued event, not proof of continuity. *)

  val next :
    ?cancel:Cancellation.t ->
    ?timeout:float ->
    t ->
    (Libtmux.Output.event option, Libtmux.Error.t) result
  (** Pump all subscription lanes until one event is available. Default deadline
      is one second. [None] follows a consumed End. A deadline keeps the
      subscription active; cancellation closes it and raises Cancelled. *)

  val close : t -> (unit, Libtmux.Error.t) result
  (** End an active subscription with Cancelled and discard pending data.
      Preserve an already ended subscription's terminal reason. Release and reap
      an unused lane; later calls retain cleanup failures. Does not stop the
      daemon. {!poll} can still read the terminal event. *)

  val wait_for_bytes :
    ?cancel:Cancellation.t ->
    ?timeout:float ->
    t ->
    text:string ->
    (Libtmux.Output.cursor, Libtmux.Output.wait_error) result
  (** Consume future bytes until the nonempty pattern matches, including across
      Data boundaries. Maximum pattern: 64 KiB. Return the cursor at the match's
      end within its consumed event. Gaps stop matching; no rendered or earlier
      output is searched. Timeout leaves the subscription active. *)
end

(** An explicit generation-bound connection. Applications retain ownership of
    the endpoint choice and resource lifetime. *)
module Client : sig
  type t

  val connect :
    ?cleanup:Cleanup.t ->
    ?binary:string ->
    ?timeout:float ->
    Libtmux.Endpoint.t ->
    (t, Libtmux.Error.t) result
  (** Attach to an existing local daemon with at least one session. The caller
      and daemon must share the PID namespace and filesystem. A local socket
      pathname alone does not establish these preconditions. [timeout] is the
      maximum seconds per control exchange, defaulting to one second. Requires
      Linux pidfd support. The client belongs to the current domain. Initial and
      auxiliary attachments suppress tmux's [update-environment] behavior. *)

  val cleanup : t -> Cleanup.t
  (** Read the report supplied at connection time, or its fresh default.
      {!Cleanup.inspect} remains available after close. *)

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
  (** Acquire verified coverage of the pane's observed session/window. Choose
      the least session ID unless explicitly supplied. Reuse one lane per
      session. Defaults: 1 MiB and 1024 queued events per subscriber; at most 16
      subscribers and eight client lanes including commands. Reserve payload
      against the shared 32 MiB budget before admission.

      Queue capacities remain reserved while empty. Captures and reads need
      additional scratch space; their admission can return
      {!Libtmux.Error.Capacity} below the subscriber-count limit. See the
      {{:https://github.com/libtmux/libtmux-ocaml/blob/master/docs/streaming.md#plan-shared-capacity}shared
       capacity guide} for the combined reservations and process slots.

      Data starts after admission's marker. Layout/membership changes end
      continuity conservatively. Overflow emits Gap then End, without blocking
      another subscriber. Blocking delivery advances during Subscription.next.
      There is no snapshot/history barrier or automatic recovery. *)

  val wait_for_text :
    ?cancel:Cancellation.t ->
    ?timeout:float ->
    ?scratch_dir:string ->
    t ->
    Libtmux.Pane.t ->
    text:string ->
    (Rendered.t, Libtmux.Error.t) result
  (** Subscribe, capture the ordinary screen immediately, and recapture after
      output. Membership/overflow gaps trigger explicit fresh capture and new
      coverage in the same binding. Maximum pattern: 64 KiB. Success returns a
      capture that contains the text. Transient text between captures may be
      missed. Check the deadline between bounded acquisitions; in-flight I/O
      retains the client's exchange timeout. Release the temporary subscription
      without replacing an earlier error or cancellation; inspect {!cleanup} for
      secondary failures. Otherwise cleanup failure prevents success or renewed
      coverage. No capture/stream barrier exists. *)

  val submit :
    t -> 'a Libtmux.Command.t -> ('a Operation.t, Libtmux.Error.t) result
  (** Validate and reserve queue capacity without I/O. *)

  val await :
    ?cancel:Cancellation.t -> 'a Operation.t -> ('a, Libtmux.Error.t) result
  (** Pump admitted work until this operation is finished. Only one blocking
      caller may own the client at a time. Cancellation removes queued work or
      drains admitted work before raising [Cancellation.Cancelled]. The handle
      retains its outcome. Draining has at most one exchange timeout from
      detection; local scratch filesystem I/O and owned-child cleanup must also
      finish. Each owned child gets 200 ms of TERM grace before forced
      termination and reaping; scheduling and kernel completion can add time. No
      background scheduler or worker is started. *)

  val run :
    ?cancel:Cancellation.t ->
    t ->
    'a Libtmux.Command.t ->
    ('a, Libtmux.Error.t) result
  (** Submit and await. Use the two calls separately to retain an operation
      handle. *)

  val capture :
    ?cancel:Cancellation.t -> t -> (Libtmux.Snapshot.t, Libtmux.Error.t) result
  (** Acquire a complete graph over a recorded interval, with a fixed number of
      listing commands. Races fail validation. Access to returned values
      performs no I/O, including after closing the client. *)

  val capture_text :
    ?cancel:Cancellation.t ->
    ?scratch_dir:string ->
    t ->
    Libtmux.Pane.t ->
    start:int ->
    end_:int ->
    (Rendered.t, Libtmux.Error.t) result
  (** Capture ordinary rendered screen rows, inclusively, via an owned paste
      buffer and private file. Reject applicable capture/save hooks. The scratch
      directory defaults to [/tmp] and must be local storage shared with the
      daemon. Pending and alternate-screen byte modes are unsupported. This
      observes an interval and establishes no stream continuity barrier. *)

  (* BEGIN GENERATED OPERATIONS *)
  val rename_window :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Window.target ->
    name:string ->
    (unit, Libtmux.Error.t) result
  (** Set the global window name. Every session link observes the new name on
      its next capture; existing snapshots retain the old value. *)

  val rename_session :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Session.target ->
    name:string ->
    (unit, Libtmux.Error.t) result
  (** Set the session name, rejecting a conflicting existing name. Bound IDs
      remain usable; existing snapshots retain their captured names. *)

  val switch_client_at :
    ?cancel:Cancellation.t ->
    ?update_environment:bool ->
    t ->
    Libtmux.Client_name.t ->
    session:Libtmux.Session.target ->
    (unit, Libtmux.Error.t) result
  (** Switch the client currently bearing this name to the bound session.
      Environment updates are disabled by default. This can move either a
      terminal client or a control client; it does not open a new terminal. *)

  val request_detach_client_at :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Client_name.t ->
    (unit, Libtmux.Error.t) result
  (** Request detachment of the client currently bearing this name. Success
      confirms request processing, not peer exit. Detaching the library's own
      primary lane can lose the response and retire its generation. *)

  val refresh_client_at :
    ?cancel:Cancellation.t ->
    ?status_only:bool ->
    t ->
    Libtmux.Client_name.t ->
    (unit, Libtmux.Error.t) result
  (** Request a redraw; no terminal-rendering completion is implied. *)

  val resize_control_client_at :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Client_name.t ->
    width:int ->
    height:int ->
    (unit, Libtmux.Error.t) result
  (** Set a control client's reported size. tmux rejects terminal clients. *)

  val send_text :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    text:string ->
    (unit, Libtmux.Error.t) result
  (** Literal bytes, without an implicit Enter. NUL is rejected at admission. *)

  val send_keys :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    Libtmux.Key.t list ->
    (unit, Libtmux.Error.t) result
  (** Send named tmux keys in order, without an implicit Enter. Use {!send_text}
      for literal bytes rather than key interpretation. *)

  val wait_for :
    ?cancel:Cancellation.t -> t -> string -> (unit, Libtmux.Error.t) result
  (** Wait on a named tmux semaphore using a dedicated bound lane. *)

  val signal :
    ?cancel:Cancellation.t -> t -> string -> (unit, Libtmux.Error.t) result
  (** Signal a named tmux semaphore, releasing a waiter or retaining the signal
      for a later {!wait_for}. This does not signal an OS process. *)

  val capture_environment :
    ?cancel:Cancellation.t ->
    ?hidden:bool ->
    t ->
    Libtmux.Environment.scope ->
    (Libtmux.Environment.t, Libtmux.Error.t) result
  (** Acquire a bounded table through a read-only command process. Its response
      must identify the bound daemon while the original pidfd remains live.
      Unsupported external variable names fail decoding; they are not omitted.
  *)

  val set_environment :
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Environment.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Remove the local entry, allowing a global value to apply to future panes.
  *)

  val remove_environment :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Environment.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Store a removal marker, excluding the variable from future panes. *)

  val capture_options :
    ?cancel:Cancellation.t ->
    ?include_inherited:bool ->
    t ->
    Libtmux.Options.scope ->
    (Libtmux.Options.t, Libtmux.Error.t) result
  (** Acquire one bounded option table, excluding hooks. The default includes
      only local entries. Inherited table enumeration includes built-ins;
      inherited user options require [read_option] with their explicit name.
      Built-in descriptors cover every supported release from tmux 3.3a through
      3.8; other versions return {!Libtmux.Error.Unsupported}. *)

  val read_option :
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
    ?index:int ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Remove a local override or one array element. Global built-ins reset to
      their tmux defaults; this does not recursively unset child overrides. *)

  val clear_option_array :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Set a local empty array, masking inheritance. *)

  val capture_hooks :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Options.scope ->
    (Libtmux.Options.t, Libtmux.Error.t) result
  (** Capture locally configured built-in hooks. Command values are tmux's
      printed representation, retained as data. *)

  val read_hook :
    ?cancel:Cancellation.t ->
    ?include_inherited:bool ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (Libtmux.Options.value option, Libtmux.Error.t) result
  (** Read an exact hook name. Inheritance is included by default; [None] means
      no entry under the selected policy. Missing targets remain errors. *)

  val set_hook :
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
    ?index:int ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Remove the local hook or one indexed array entry. An inherited hook may
      become effective again; this does not stop work it already started. *)

  val run_hook :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Options.scope ->
    string ->
    (unit, Libtmux.Error.t) result
  (** Run the effective hook in an explicit session, window or pane context. A
      successful result follows completion of its synchronous command queue.
      Background work started by a hook has its own lifetime. A later hook
      failure returns an uncertain outcome; preceding effects remain. Named [@]
      hooks return [Unsupported] because tmux can hide their parse failures in
      the server log. Configuration and inspection remain available. *)

  val create_session :
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
    ?index:int ->
    ?name:string ->
    ?spawn:Libtmux.Spawn.t ->
    t ->
    Libtmux.Session.target ->
    (Libtmux.Created.t, Libtmux.Error.t) result
  (** Create detached, rejecting an occupied explicit index. *)

  val split_pane :
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Session.target ->
    (unit, Libtmux.Error.t) result
  (** Remove the session and its window links. Windows with no other links and
      their panes are destroyed. Removing the last session may stop tmux. *)

  val kill_window :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Window.target ->
    (unit, Libtmux.Error.t) result
  (** Destroy the window, all its session links and every contained pane. This
      acts on the global window, not a single contextual link. *)

  val kill_pane :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Destroy the target pane and its running process. tmux removes a window
      that becomes empty and may remove its now-empty sessions. *)

  val select_window_at :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Operate on the session's current index at execution, not an old link
      incarnation. *)

  val unlink_window_at :
    ?cancel:Cancellation.t ->
    ?allow_kill:bool ->
    t ->
    Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Without [allow_kill], tmux rejects removal of the last link to a window.
  *)

  val link_window :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Window.target ->
    session:Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Add a session-specific link to the global window at [index], rejecting an
      occupied index. The source window and its panes stay shared. *)

  val move_window_at :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Session.target ->
    from_index:int ->
    session:Libtmux.Session.target ->
    index:int ->
    (unit, Libtmux.Error.t) result
  (** Move the source session's current link at [from_index]. Destination
      collisions fail. *)

  val select_pane :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Make the pane active in its containing window. This does not open or
      attach a terminal client. *)

  val set_pane_title :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    title:string ->
    (unit, Libtmux.Error.t) result
  (** Set the pane title as literal text, without tmux format expansion. A
      running terminal application can subsequently replace the title. *)

  val resize_pane :
    ?cancel:Cancellation.t ->
    ?width:int ->
    ?height:int ->
    t ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Request positive cell dimensions, supplying at least one dimension. Omit
      either dimension to retain it. tmux can constrain the result to the
      available layout. Capture again to observe the actual dimensions. *)

  val resize_window :
    ?cancel:Cancellation.t ->
    ?width:int ->
    ?height:int ->
    t ->
    Libtmux.Window.target ->
    (unit, Libtmux.Error.t) result
  (** Request positive cell dimensions, supplying at least one dimension. Omit
      either dimension to retain it. Client-size and window-size policies can
      affect subsequent sizing. *)

  val select_layout :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Window.target ->
    Libtmux.Layout.t ->
    (unit, Libtmux.Error.t) result
  (** Apply a preset or validated custom layout to the window. Pane geometry
      follows tmux layout rules; capture again to observe the result. *)

  val cycle_layout :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Window.target ->
    [ `Next | `Previous ] ->
    (unit, Libtmux.Error.t) result
  (** Select the next or previous tmux preset layout for this window. *)

  val move_pane :
    ?cancel:Cancellation.t ->
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
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Exchange pane positions without exchanging their identities or running
      processes. Both targets must belong to the same bound generation. *)

  val rotate_panes :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Window.target ->
    [ `Forward | `Backward ] ->
    (unit, Libtmux.Error.t) result
  (** Rotate pane positions in the selected direction. Pane identities and
      running processes remain attached to their panes. *)

  val zoom_pane :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Toggle the window's zoom state around this pane. *)

  val respawn_pane :
    ?cancel:Cancellation.t ->
    ?kill_running:bool ->
    t ->
    Libtmux.Pane.target ->
    Libtmux.Spawn.t ->
    (unit, Libtmux.Error.t) result
  (** Start the supplied command in the existing pane. A running process causes
      failure unless [kill_running:true] explicitly replaces it. The pane ID
      remains unchanged. *)

  val clear_history :
    ?cancel:Cancellation.t ->
    t ->
    Libtmux.Pane.target ->
    (unit, Libtmux.Error.t) result
  (** Clear stored scrollback for this pane. The visible screen and running
      process remain; later captures cannot recover discarded history. *)

  (* END GENERATED OPERATIONS *)

  val close : t -> (unit, Libtmux.Error.t) result
  (** Close owned control clients and descriptors on the owning domain. Later
      calls retain the original cleanup result, including failure. Each owned
      helper gets 200 ms of TERM grace, followed by KILL if needed and reaping.
      This is not a whole-client deadline or a bound on uninterruptible kernel
      work. No signal targets the daemon. tmux's [exit-unattached] and
      [exit-empty] policies can end the daemon after its clients or sessions
      disappear. *)
end

(** Apply validated plans with blocking I/O and scoped cancellation tokens.
    Execution handles retain journals and borrow existing clients; bootstrap
    handles own their newly bound clients without owning the daemon. *)
module Workspace : sig
  type t

  val submit :
    Client.t -> Libtmux_workspace.Plan.t -> (t, Libtmux.Error.t) result
  (** Allocate a generation-bound execution handle without I/O. The caller owns
      the supplied client; closing this handle leaves that client open. *)

  val submit_bootstrap :
    ?cleanup:Cleanup.t ->
    ?binary:string ->
    ?timeout:float ->
    Libtmux_workspace.Plan.t ->
    (t, Libtmux.Error.t) result
  (** Allocate a handle for a missing-endpoint plan. Awaiting it starts control
      new-session and binds the same connection. The handle owns its new client;
      it never acquires ownership of the daemon. *)

  val await :
    ?cancel:Cancellation.t ->
    ?compensate_on_failure:bool ->
    t ->
    (Libtmux_workspace.Execution.receipt, Libtmux.Error.t) result
  (** Expected apply failures are retained receipts. Cancellation propagates
      after recording progress and at most 500 ms of protected compensation. *)

  val inspect :
    t -> (Libtmux_workspace.Execution.receipt, Libtmux.Error.t) result

  val client : t -> Client.t option
  (** Borrow the existing or bootstrapped {!Client.t} without I/O for subsequent
      actions or recovery. {!close} releases a client owned by this workspace
      execution handle. *)

  val close : t -> (unit, Libtmux.Error.t) result
  (** Release an owned client through {!Client.close}. Active await returns
      Busy. Completed journals remain readable after close. *)
end
