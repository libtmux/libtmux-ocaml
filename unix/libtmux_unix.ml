module Rendered = Libtmux.Captured_text
module Cancellation = Cancellation
module Terminal = Terminal

module Operation = struct
  type 'a t = 'a Engine.operation

  type cleanup_receipt = Engine.cleanup_receipt = {
    cause : Libtmux.Error.t;
    owned_buffers : string list;
    created : Libtmux.Created.t list;
  }

  type 'a state = 'a Engine.state =
    | Queued
    | Not_started
    | Written
    | Acknowledged
    | Finished of ('a, Libtmux.Error.t) result
    | Outcome_unknown of cleanup_receipt

  let inspect op = Runtime_io.protect (fun () -> Engine.inspect op)

  let cancel op =
    Runtime_io.protect (fun () ->
        Connection.exclusive op.Engine.client.connection (fun () ->
            Engine.cancel op))

  let id = Engine.id
end

module Subscription = struct
  type t = Streaming.subscription

  let poll sub = Runtime_io.protect (fun () -> Streaming.poll sub)

  let close sub =
    Runtime_io.protect (fun () ->
        Connection.exclusive sub.Streaming.manager.connection (fun () ->
            Streaming.close sub))

  let next ?cancel ?(timeout = 1.) sub =
    Runtime_io.protect (fun () ->
        Connection.exclusive sub.Streaming.manager.connection (fun () ->
            Streaming.next ?cancel ~timeout sub))

  let wait_for_bytes ?cancel ?(timeout = 1.) sub ~text =
    Streaming.wait_for_bytes ~timeout sub ~text ~next:(fun timeout ->
        next ?cancel ~timeout sub)
end

module Client = struct
  type t = { engine : Engine.t; streams : Streaming.t }

  let connect ?(binary = "tmux") ?timeout endpoint =
    Runtime_io.protect (fun () ->
        let connection =
          Connection.connect ?timeout ~io:Runtime_io.blocking ~binary endpoint
        in
        {
          engine = Engine.create connection;
          streams = Streaming.create ~changed:(fun () -> ()) connection;
        })

  let source t = t.engine.connection.source
  let version t = t.engine.connection.version

  let close t =
    Runtime_io.protect (fun () ->
        Connection.exclusive t.engine.connection (fun () ->
            Streaming.close_all t.streams Libtmux.Output.Client_closed;
            Engine.close t.engine))

  let submit t command =
    Runtime_io.protect (fun () ->
        Connection.exclusive t.engine.connection (fun () ->
            Engine.submit t.engine command))

  let await_owned ?cancel op =
    match cancel with
    | None -> Engine.await_owned op
    | Some token -> Cancellation.await op token

  let await ?cancel op =
    Runtime_io.protect (fun () ->
        Connection.exclusive op.Engine.client.connection (fun () ->
            await_owned ?cancel op))

  let run ?cancel t command =
    Runtime_io.protect (fun () ->
        Connection.exclusive t.engine.connection (fun () ->
            await_owned ?cancel (Engine.submit t.engine command)))

  let subscribe ?session ?capacity_bytes ?capacity_events t pane =
    Runtime_io.protect (fun () ->
        Connection.exclusive t.engine.connection (fun () ->
            Streaming.subscribe ?session ?capacity_bytes ?capacity_events
              t.streams pane))

  let capture ?cancel t = run ?cancel t (Libtmux.Operations.capture ())

  include Generated_operations.Make (struct
    type nonrec t = t

    let run = run
  end)

  let capture_text ?cancel ?scratch_dir t pane ~start ~end_ =
    run ?cancel t
      (Libtmux.Operations.capture_text ?scratch_dir pane ~start ~end_)

  let wait_for_text ?cancel ?(timeout = 1.) ?scratch_dir t pane ~text =
    Runtime_io.protect (fun () ->
        Observation_wait.rendered ~connection:t.engine.connection
          ~capture:(fun () -> capture ?cancel t)
          ~capture_text:(fun pane ->
            capture_text ?cancel ?scratch_dir t pane ~start:0
              ~end_:(Libtmux.Pane.height pane - 1))
          ~subscribe:(subscribe t)
          ~next:(fun timeout sub -> Subscription.next ?cancel ~timeout sub)
          ~poll:Subscription.poll ~close:Subscription.close ~timeout pane ~text)
end

module Workspace = struct
  module X = Libtmux_workspace.Execution
  module P = Libtmux_workspace.Plan
  module R = Workspace_runner

  type t = {
    journal : X.t;
    owner : Domain.id;
    current : Client.t option ref;
    owned : bool;
    cancel : Cancellation.t option ref;
    busy : bool Atomic.t;
    mutable closed : bool;
  }

  let owner t =
    if Domain.self () <> t.owner then Runtime_io.fail Libtmux.Error.Wrong_domain

  let describe cancel (client : Client.t) : R.client =
    {
      source = Client.source client;
      version = Client.version client;
      capture = (fun () -> Client.capture ?cancel:!cancel client);
      submit =
        (fun command ->
          Result.map
            (fun operation ->
              R.
                {
                  await = (fun () -> Client.await ?cancel:!cancel operation);
                  observe = R.observe operation;
                })
            (Client.submit client command));
    }

  let cancel_io token f =
    match token with
    | None -> f Runtime_io.blocking
    | Some token ->
        Cancellation.borrow token (fun reader ->
            let check () =
              if Cancellation.is_cancelled token then
                raise Cancellation.Cancelled
            in
            let base = Runtime_io.blocking in
            let wait ~read ~write ~deadline =
              check ();
              base.wait ~read:(reader :: read) ~write ~deadline;
              check ()
            in
            f { base with check; wait })

  let create ?client ?(binary = "tmux") ?timeout ~owned plan =
    let current = ref client and cancel = ref None in
    let protect f =
      let previous = !cancel in
      cancel := None;
      Fun.protect
        ~finally:(fun () -> cancel := previous)
        (fun () ->
          match !current with
          | None -> Runtime_io.protect f
          | Some client ->
              let connection = client.Client.engine.connection in
              let base = connection.lane.io in
              let deadline = Linux.now () +. 0.5 in
              let check () =
                base.check ();
                if Linux.now () >= deadline then
                  Runtime_io.fail Libtmux.Error.Deadline_exceeded
              in
              let wait ~read ~write ~deadline:requested =
                check ();
                base.wait ~read ~write ~deadline:(min requested deadline)
              in
              Fun.protect
                ~finally:(fun () -> connection.lane.io <- base)
                (fun () ->
                  connection.lane.io <- { base with check; wait };
                  Runtime_io.protect f))
    in
    let bootstrap receipt config =
      Runtime_io.protect (fun () ->
          let first = Iarray.get (Libtmux_workspace.Config.windows config) 0 in
          let width, height = Libtmux_workspace.Config.dimensions config in
          let connection, created =
            cancel_io !cancel (fun io ->
                Bootstrap.start receipt ?timeout ~io ~binary
                  ~endpoint:(P.endpoint plan)
                  ~name:(Libtmux_workspace.Config.session config)
                  ~window_name:first.name ~spawn:(List.hd first.panes).spawn
                  ~width ~height ())
          in
          connection.lane.io <- Runtime_io.blocking;
          let client =
            Client.
              {
                engine = Engine.create connection;
                streams = Streaming.create ~changed:(fun () -> ()) connection;
              }
          in
          current := Some client;
          (describe cancel client, created))
    in
    let executor =
      R.create ~client:(Option.map (describe cancel) client) ~bootstrap ~protect
    in
    Result.map
      (fun journal ->
        {
          journal;
          owner = Domain.self ();
          current;
          owned;
          cancel;
          busy = Atomic.make false;
          closed = false;
        })
      (X.create ~operation_id:(Linux.nonce ()) ~executor plan)

  let submit client plan = create ~client ~owned:false plan

  let submit_bootstrap ?binary ?timeout plan =
    if Option.is_some (P.source plan) then Error Libtmux.Error.Stale_target
    else create ?binary ?timeout ~owned:true plan

  let inspect t =
    Runtime_io.protect (fun () ->
        owner t;
        X.inspect t.journal)

  let await ?cancel ?compensate_on_failure t =
    Runtime_io.protect (fun () ->
        owner t;
        if t.closed then Runtime_io.fail Libtmux.Error.Closed;
        if not (Atomic.compare_and_set t.busy false true) then
          Runtime_io.fail Libtmux.Error.Busy;
        Fun.protect
          ~finally:(fun () ->
            t.cancel := None;
            Atomic.set t.busy false)
          (fun () ->
            t.cancel := cancel;
            X.await ?compensate_on_failure t.journal))

  let client t = !(t.current)

  let close t =
    Runtime_io.protect (fun () ->
        owner t;
        if Atomic.get t.busy then Runtime_io.fail Libtmux.Error.Busy;
        if not t.closed then (
          t.closed <- true;
          if t.owned then
            Option.iter
              (fun client -> Runtime_io.get (Client.close client))
              !(t.current)))
end
