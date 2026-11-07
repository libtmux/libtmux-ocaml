exception Cancelled

type t = {
  cancelled : bool Atomic.t;
  mutex : Mutex.t;
  reader : Unix.file_descr;
  writer : Unix.file_descr;
  mutable closed : bool;
  mutable users : int;
}

let locked t f = Mutex.protect t.mutex f
let is_cancelled t = Atomic.get t.cancelled

let signal t =
  if not (Atomic.exchange t.cancelled true) then
    let rec write () =
      try ignore (Unix.write_substring t.writer "x" 0 1) with
      | Unix.Unix_error (Unix.EINTR, _, _) -> write ()
      | Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> ()
    in
    write ()

let cancel t = locked t (fun () -> if not t.closed then signal t)

let release t =
  t.users <- t.users - 1;
  if t.users = 0 then (
    Runtime_io.close_fd t.reader;
    Runtime_io.close_fd t.writer)

let with_ f =
  let reader, writer = Unix.pipe ~cloexec:true () in
  (try
     Unix.set_nonblock reader;
     Unix.set_nonblock writer
   with exn ->
     Runtime_io.close_fd reader;
     Runtime_io.close_fd writer;
     raise exn);
  let t =
    {
      cancelled = Atomic.make false;
      mutex = Mutex.create ();
      reader;
      writer;
      closed = false;
      users = 1;
    }
  in
  Fun.protect
    ~finally:(fun () ->
      locked t (fun () ->
          signal t;
          t.closed <- true;
          release t))
    (fun () -> f t)

let borrow t f =
  locked t (fun () ->
      if t.closed then raise Cancelled;
      t.users <- t.users + 1);
  Fun.protect
    ~finally:(fun () -> locked t (fun () -> release t))
    (fun () -> f t.reader)

let await op t =
  let connection = op.Engine.client.connection in
  try
    borrow t (fun reader ->
        if is_cancelled t then (
          Engine.cancel op;
          raise Cancelled);
        let base = connection.lane.io in
        let drain_deadline = ref None in
        let check () =
          base.check ();
          if is_cancelled t && !drain_deadline = None then (
            Engine.cancel op;
            drain_deadline := Some (Linux.now () +. connection.timeout));
          match !drain_deadline with
          | Some deadline when Linux.now () >= deadline ->
              Runtime_io.fail Libtmux.Error.Deadline_exceeded
          | _ -> ()
        in
        let wait ~read ~write ~deadline =
          check ();
          let read, deadline =
            match !drain_deadline with
            | None -> (reader :: read, deadline)
            | Some drain -> (read, min deadline drain)
          in
          base.wait ~read ~write ~deadline;
          check ()
        in
        Fun.protect
          ~finally:(fun () -> connection.lane.io <- base)
          (fun () ->
            connection.lane.io <- { base with check; wait };
            match Runtime_io.protect (fun () -> Engine.await_owned op) with
            | result ->
                if is_cancelled t then raise Cancelled;
                Runtime_io.get result))
  with Cancelled ->
    Engine.cancel op;
    raise Cancelled
