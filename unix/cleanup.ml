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

type t = {
  owner : Domain.id;
  mutable reversed : issue list;
  mutable count : int;
  mutable omitted : int;
}

let create () =
  { owner = Domain.self (); reversed = []; count = 0; omitted = 0 }

let check t =
  if Domain.self () <> t.owner then raise (Failure Libtmux.Error.Wrong_domain)

let inspect t =
  if Domain.self () <> t.owner then Error Libtmux.Error.Wrong_domain
  else Ok { issues = Iarray.of_list (List.rev t.reversed); omitted = t.omitted }

let record t phase exception_ backtrace =
  check t;
  if t.count = 64 then t.omitted <- min (max_int - 1) t.omitted + 1
  else
    let error =
      match exception_ with Failure error -> Some error | _ -> None
    in
    t.reversed <- { phase; error; exception_; backtrace } :: t.reversed;
    t.count <- t.count + 1

let attempt t phase f =
  check t;
  match f () with
  | value -> Ok value
  | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      record t phase exn bt;
      Error (exn, bt)

let get = function
  | Ok value -> value
  | Error (exn, bt) -> Printexc.raise_with_backtrace exn bt

let step t phase f = get (attempt t phase f)

(* Leaves record failures; composition only preserves and propagates them. *)
let run actions =
  let first = ref None in
  List.iter
    (fun action ->
      try action ()
      with exn ->
        let bt = Printexc.get_raw_backtrace () in
        if !first = None then first := Some (exn, bt))
    actions;
  Option.iter (fun (exn, bt) -> Printexc.raise_with_backtrace exn bt) !first

let protect ~finally f =
  match f () with
  | value ->
      finally ();
      value
  | exception exn ->
      let bt = Printexc.get_raw_backtrace () in
      (* Every failing leaf in [finally] records its own issue. A secondary
         failure must not replace this exception, especially cancellation. *)
      (try finally () with _ -> ());
      Printexc.raise_with_backtrace exn bt
