module P = Plan
open Libtmux

type hint = {
  session : Session.Id.t;
  window : Window.Id.t;
  pane : Pane.Id.t;
  window_index : int;
  pane_index : int;
  server_pid : int;
}

type certainty = Not_started | Applied | Unknown

type observation = {
  certainty : certainty;
  created : Created.t list;
  unbound : hint option;
}

type executor = {
  source : unit -> Source.t option;
  capture : unit -> (Snapshot.t, Error.t) result;
  run : 'a. 'a Command.t -> ('a, Error.t) result;
  bootstrap : Config.t -> (Created.t, Error.t) result;
  inspect : unit -> unit -> observation;
  protect : (unit -> unit) -> (unit, Error.t) result;
}

type step_status =
  | Pending
  | Running
  | Completed
  | Failed of Error.t
  | Skipped
  | Uncertain of Error.t

type step = {
  index : int;
  action : P.action;
  status : step_status;
  created : Created.t list;
  unbound : hint option;
}

type cleanup = { pane : Pane.target; outcome : (unit, Error.t) result }

type status =
  | Queued
  | Applying
  | Succeeded
  | Partial
  | Interrupted
  | Rejected of P.error
  | Unavailable of Error.t

type receipt = {
  operation_id : string;
  source : Source.t option;
  status : status;
  steps : step Iarray.t;
  cleanup : cleanup Iarray.t;
  cleanup_error : Error.t option;
}

type t = {
  operation_id : string;
  plan : P.t;
  executor : executor;
  mutable status : status;
  steps : step array;
  mutable cleanup : cleanup list;
  mutable owned : Pane.target list;
  mutable session : Session.target option;
  mutable cleanup_error : Error.t option;
  mutable pending : (int * (unit -> observation)) option;
  windows : (int, Window.target) Hashtbl.t;
  panes : (int * int, Pane.target) Hashtbl.t;
}

exception Stop

let create ~operation_id ~executor plan =
  if
    operation_id = ""
    || String.length operation_id > 64
    || not
         (String.for_all
            (function
              | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
              | _ -> false)
            operation_id)
  then
    Error
      (Error.Invalid_input
         "operation ID requires 1..64 ASCII letters, digits, '_' or '-'")
  else
    Ok
      {
        operation_id;
        plan;
        executor;
        status = Queued;
        steps =
          P.actions plan |> Iarray.to_seq
          |> Seq.mapi (fun index action ->
              { index; action; status = Pending; created = []; unbound = None })
          |> Array.of_seq;
        cleanup = [];
        cleanup_error = None;
        pending = None;
        owned = [];
        session = P.existing_session plan;
        windows = Hashtbl.create 8;
        panes = Hashtbl.create 8;
      }

let inspect (t : t) : receipt =
  Option.iter
    (fun (index, observe) ->
      let current = observe () in
      let step = t.steps.(index) in
      let status =
        match current.certainty with
        | Applied -> Completed
        | Not_started -> Skipped
        | Unknown -> step.status
      in
      t.steps.(index) <-
        {
          step with
          status;
          created = current.created;
          unbound = current.unbound;
        })
    t.pending;
  {
    operation_id = t.operation_id;
    source = t.executor.source ();
    status = t.status;
    steps = Iarray.of_seq (Array.to_seq t.steps);
    cleanup = Iarray.of_list (List.rev t.cleanup);
    cleanup_error = t.cleanup_error;
  }

let skip_pending (t : t) =
  Array.iteri
    (fun index (step : step) ->
      if step.status = Pending then
        t.steps.(index) <- { step with status = Skipped })
    t.steps

let remember (t : t) created =
  List.iter
    (fun (value : Created.t) ->
      if
        not
          (List.exists
             (fun pane ->
               Pane.Id.equal (Pane.Target.id pane) (Pane.Target.id value.pane))
             t.owned)
      then t.owned <- value.pane :: t.owned)
    created

let settle (t : t) index ~error ~interrupted =
  let observe = t.executor.inspect () in
  let observation = observe () in
  if observation.certainty = Unknown then t.pending <- Some (index, observe);
  let step = t.steps.(index) in
  let status =
    match observation.certainty with
    | Unknown -> Uncertain error
    | Applied when interrupted -> Completed
    | Not_started when interrupted -> Skipped
    | Applied | Not_started -> Failed error
  in
  t.steps.(index) <-
    {
      step with
      status;
      created = observation.created;
      unbound = observation.unbound;
    };
  remember t observation.created

let compensate (t : t) =
  let result =
    t.executor.protect (fun () ->
        List.iter
          (fun pane ->
            t.cleanup <-
              {
                pane;
                outcome =
                  Error (Error.Outcome_unknown "compensation has not returned");
              }
              :: t.cleanup;
            let outcome = t.executor.run (Operations.kill_pane pane) in
            t.cleanup <- { pane; outcome } :: List.tl t.cleanup)
          t.owned)
  in
  match result with Ok () -> () | Error error -> t.cleanup_error <- Some error

let await ?(compensate_on_failure = true) (t : t) =
  if t.status <> Queued then inspect t
  else
    let rejected error =
      t.status <- Rejected error;
      skip_pending t;
      inspect t
    in
    match P.check_source t.plan (t.executor.source ()) with
    | Error error -> rejected error
    | Ok () -> (
        t.status <- Applying;
        let active = ref None in
        let get = function
          | Ok value -> value
          | Error error ->
              Option.iter
                (fun index -> settle t index ~error ~interrupted:false)
                !active;
              raise Stop
        in
        let require = function
          | Some value -> value
          | None -> failwith "workspace plan has an unresolved resource"
        in
        let window index = require (Hashtbl.find_opt t.windows index) in
        let pane wi pi = require (Hashtbl.find_opt t.panes (wi, pi)) in
        let session () = require t.session in
        let perform index (action : P.action) =
          let created = ref [] in
          let remember_created wi pi value =
            created := [ value ];
            Hashtbl.replace t.panes (wi, pi) value.Created.pane
          in
          let run command = get (t.executor.run command) in
          (match action with
          | Create_session
              { bootstrap; name; window_name; spawn; width; height } ->
              let value =
                if bootstrap then get (t.executor.bootstrap (P.config t.plan))
                else
                  run
                    (Operations.create_session ~name ~window_name ~spawn ~width
                       ~height ())
              in
              t.session <- Some value.session;
              Hashtbl.replace t.windows 0 value.window;
              remember_created 0 0 value
          | Create_window { window = wi; name; spawn } ->
              let value =
                run (Operations.create_window ~name ~spawn (session ()))
              in
              Hashtbl.replace t.windows wi value.window;
              remember_created wi 0 value
          | Split_pane { window = wi; pane = pi; spawn; direction; size } ->
              let value =
                run
                  (Operations.split_pane ?size ~spawn
                     (pane wi (pi - 1))
                     ~direction)
              in
              if
                not
                  (Window.Id.equal
                     (Window.Target.id (window wi))
                     (Window.Target.id value.window))
              then ignore (get (Error Error.Stale_target));
              remember_created wi pi value
          | Set_environment (name, value) ->
              run
                (Operations.set_environment
                   (Environment.Session (session ()))
                   ~name value)
          | Set_option (scope, setting) ->
              let scope =
                match scope with
                | P.Session -> Options.Session (session ())
                | Window wi -> Options.Window (window wi)
                | Pane { window = wi; pane = pi } -> Options.Pane (pane wi pi)
              in
              run
                (Operations.set_option ?index:setting.index scope
                   ~name:setting.name setting.value)
          | Send_text { window = wi; pane = pi; text } ->
              run (Operations.send_text (pane wi pi) ~text)
          | Send_enter { window = wi; pane = pi } ->
              run (Operations.send_keys (pane wi pi) [ Key.Enter ])
          | Select_layout (wi, layout) ->
              run (Operations.select_layout (window wi) layout));
          let step = t.steps.(index) in
          t.steps.(index) <-
            { step with status = Completed; created = !created };
          remember t !created
        in
        let cleanup () =
          skip_pending t;
          if compensate_on_failure then compensate t
        in
        try
          (match P.source t.plan with
          | None -> ()
          | Some _ -> (
              let snapshot =
                match t.executor.capture () with
                | Ok snapshot -> snapshot
                | Error error ->
                    t.status <- Unavailable error;
                    raise Stop
              in
              match P.recheck t.plan snapshot with
              | Ok () -> ()
              | Error error ->
                  t.status <- Rejected error;
                  raise Stop));
          Array.iteri
            (fun index (step : step) ->
              active := Some index;
              t.steps.(index) <- { step with status = Running };
              perform index step.action;
              active := None)
            t.steps;
          t.status <- Succeeded;
          inspect t
        with
        | Stop ->
            if t.status = Applying then t.status <- Partial;
            cleanup ();
            inspect t
        | exn ->
            Option.iter
              (fun index ->
                settle t index
                  ~error:
                    (Error.Outcome_unknown "workspace execution interrupted")
                  ~interrupted:true)
              !active;
            t.status <- Interrupted;
            cleanup ();
            raise exn)
