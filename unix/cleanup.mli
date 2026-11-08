(** @canonical Libtmux_unix.Cleanup *)

exception Failure of Libtmux.Error.t

type phase =
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

type issue = {
  phase : phase;
  error : Libtmux.Error.t option;
  exception_ : exn;
  backtrace : Printexc.raw_backtrace;
}

type snapshot = { issues : issue Iarray.t; omitted : int }
type t

val create : unit -> t
val inspect : t -> (snapshot, Libtmux.Error.t) result
val check : t -> unit
val record : t -> phase -> exn -> Printexc.raw_backtrace -> unit

val attempt :
  t -> phase -> (unit -> 'a) -> ('a, exn * Printexc.raw_backtrace) result

val get : ('a, exn * Printexc.raw_backtrace) result -> 'a
val step : t -> phase -> (unit -> 'a) -> 'a
val run : (unit -> unit) list -> unit
val protect : finally:(unit -> unit) -> (unit -> 'a) -> 'a
