open Libtmux
module X = Libtmux_workspace.Execution

type 'a call = {
  await : unit -> ('a, Error.t) result;
  observe : unit -> X.observation;
}

type client = {
  source : Source.t;
  version : string;
  capture : unit -> (Snapshot.t, Error.t) result;
  submit : 'a. 'a Command.t -> ('a call, Error.t) result;
}

let not_started () = X.{ certainty = Not_started; created = []; unbound = None }

let observe op () =
  let certainty =
    match Engine.inspect op with
    | Queued | Not_started -> X.Not_started
    | Finished (Ok _) -> Applied
    | Finished (Error _) when op.Engine.created = [] -> Not_started
    | Written | Acknowledged | Finished (Error _) | Outcome_unknown _ -> Unknown
  in
  X.{ certainty; created = op.Engine.created; unbound = None }

let bootstrap_observation receipt () =
  match receipt.Bootstrap.state with
  | Queued | Rejected _ -> not_started ()
  | Admitted -> X.{ certainty = Unknown; created = []; unbound = None }
  | Bound created ->
      X.{ certainty = Applied; created = [ created ]; unbound = None }
  | Reported hint ->
      X.
        {
          certainty = Unknown;
          created = [];
          unbound =
            Some
              {
                session = hint.session;
                window = hint.window;
                pane = hint.pane;
                window_index = hint.window_index;
                pane_index = hint.pane_index;
                server_pid = hint.server_pid;
              };
        }

let create ~client ~bootstrap ~protect =
  let current = ref client in
  let pending = ref not_started in
  let run : type a. a Command.t -> (a, Error.t) result =
   fun command ->
    pending := not_started;
    match !current with
    | None -> Error Error.Closed
    | Some client ->
        Result.bind (client.submit command) (fun call ->
            pending := call.observe;
            call.await ())
  in
  X.
    {
      source =
        (fun () -> Option.map (fun (client : client) -> client.source) !current);
      capture =
        (fun () ->
          match !current with
          | None -> Error Error.Closed
          | Some client -> client.capture ());
      run;
      bootstrap =
        (fun config ->
          let receipt = Bootstrap.create () in
          pending := bootstrap_observation receipt;
          Result.bind (bootstrap receipt config)
            (fun ((client : client), created) ->
              current := Some client;
              match
                Libtmux_workspace.Plan.make
                  ~endpoint:(Source.endpoint client.source)
                  ~version:client.version ~observed:None config
              with
              | Ok _ -> Ok created
              | Error error ->
                  Error
                    (Error.Unsupported
                       (Format.asprintf "%a" Libtmux_workspace.Plan.pp_error
                          error))));
      inspect = (fun () -> !pending);
      protect;
    }
