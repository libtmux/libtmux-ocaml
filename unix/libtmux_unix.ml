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
          ~close:Subscription.close ~timeout pane ~text)
end
