open Libtmux
module Config = Libtmux_workspace.Config
module P = Libtmux_workspace.Plan
module X = Libtmux_workspace.Execution

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let config ~session windows =
  match Config.make ~directory:"/tmp" ~session windows with
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Config.pp_error error)

let pane ?size () = Config.pane ?size ~spawn:(Spawn.make (Shell "exec cat")) ()
let window name panes = Config.window ~name panes

module type Backend = sig
  module C : sig
    type t

    val connect : binary:string -> Endpoint.t -> (t, Error.t) result
    val source : t -> Source.t
    val version : t -> string
    val capture : t -> (Snapshot.t, Error.t) result
    val run : t -> 'a Command.t -> ('a, Error.t) result
    val close : t -> (unit, Error.t) result
  end

  module W : sig
    type t

    val submit : C.t -> P.t -> (t, Error.t) result
    val submit_bootstrap : binary:string -> P.t -> (t, Error.t) result
    val client : t -> C.t option
    val await : ?compensate_on_failure:bool -> t -> (X.receipt, Error.t) result
    val inspect : t -> (X.receipt, Error.t) result
    val close : t -> (unit, Error.t) result
  end

  val read_line : unit -> string
  val cancel : W.t -> unit
end

module Make (B : Backend) = struct
  module C = B.C
  module W = B.W

  let run_bootstrap ~binary ~endpoint ~version =
    let cfg =
      config ~session:"workspace-public-bootstrap"
        [ window "editor" [ pane (); pane () ]; window "logs" [ pane () ] ]
    in
    let plan =
      match P.make ~endpoint ~version ~observed:None cfg with
      | Ok plan -> plan
      | Error error -> failwith (Format.asprintf "%a" P.pp_error error)
    in
    let operation = get (W.submit_bootstrap ~binary plan) in
    assert ((get (W.inspect operation)).status = X.Queued);
    assert (Option.is_none (W.client operation));
    let receipt = get (W.await operation) in
    assert (receipt.status = X.Succeeded);
    let client = Option.get (W.client operation) in
    let source = C.source client in
    let snapshot = get (C.capture client) in
    let session =
      Snapshot.sessions snapshot
      |> Iarray.find_opt (fun session ->
          Session.name session = Config.session cfg)
      |> Option.get
    in
    assert (Iarray.length (Session.windows session) = 2);
    let pane =
      Iarray.get (Window.panes (Iarray.get (Session.windows session) 0)) 0
    in
    Printf.printf "READY %d %d\n%!" (Source.server_pid source)
      (Option.get (Pane.pid pane));
    assert (B.read_line () = "continue");
    ignore (get (W.close operation));
    ignore (get (W.close operation));
    assert ((get (W.inspect operation)).status = X.Succeeded);
    assert (Iarray.length (Session.windows session) = 2);
    let probe = get (C.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (C.close probe)))
      (fun () ->
        assert (Source.server_pid (C.source probe) = Source.server_pid source);
        ignore (get (C.capture probe));
        let collision = get (W.submit_bootstrap ~binary plan) in
        let receipt = get (W.await collision) in
        assert (receipt.status = X.Partial);
        assert (Iarray.length receipt.cleanup = 0);
        assert (Option.is_none (W.client collision));
        assert (
          Iarray.exists
            (fun (step : X.step) ->
              match step.status with
              | Failed (Error.Command_failed { command = "new-session"; _ }) ->
                  true
              | _ -> false)
            receipt.steps);
        ignore (get (W.close collision)));
    print_endline
      "PASS public bootstrap, collision, closed-client journal, healthy daemon";
    print_endline "CLOSED"

  let run ~binary ~endpoint =
    let client = get (C.connect ~binary endpoint) in
    Fun.protect
      ~finally:(fun () -> ignore (get (C.close client)))
      (fun () ->
        let initial = get (C.capture client) in
        let run command = get (C.run client command) in
        let plan ?collision_policy cfg =
          let observed = get (C.capture client) in
          match
            P.make ?collision_policy
              ~endpoint:(Source.endpoint (C.source client))
              ~version:(C.version client) ~observed:(Some observed) cfg
          with
          | Ok plan -> plan
          | Error error -> failwith (Format.asprintf "%a" P.pp_error error)
        in
        let execute ?compensate_on_failure plan =
          let operation = get (W.submit client plan) in
          Fun.protect
            ~finally:(fun () -> ignore (get (W.close operation)))
            (fun () ->
              let receipt = get (W.await ?compensate_on_failure operation) in
              let again = get (W.await operation) in
              assert (receipt.operation_id = again.operation_id);
              assert (receipt.status = again.status);
              receipt)
        in
        let good =
          config ~session:"workspace-success"
            [ window "editor" [ pane (); pane () ]; window "logs" [ pane () ] ]
        in
        let receipt = execute (plan good) in
        assert (
          receipt.status = X.Succeeded && Iarray.length receipt.cleanup = 0);
        assert (
          Iarray.for_all
            (fun (step : X.step) -> step.status = Completed)
            receipt.steps);
        let snapshot = get (C.capture client) in
        let session =
          Snapshot.sessions snapshot
          |> Iarray.find_opt (fun session ->
              Session.name session = "workspace-success")
          |> Option.get
        in
        assert (Iarray.length (Session.windows session) = 2);
        assert (
          Session.windows session |> Iarray.to_seq |> Seq.map Window.panes
          |> Seq.map Iarray.length |> Seq.fold_left ( + ) 0 = 3);
        let impossible =
          config ~session:"workspace-partial"
            [
              window "first" [ pane () ];
              window "second"
                [ pane (); pane ~size:(Geometry.Cells 1) (); pane () ];
              window "skipped" [ pane () ];
            ]
        in
        let receipt = execute (plan impossible) in
        assert (receipt.status = X.Partial);
        assert (
          Iarray.exists
            (fun (step : X.step) ->
              match step.status with Failed _ -> true | _ -> false)
            receipt.steps);
        assert (Iarray.length receipt.cleanup = 3);
        assert (
          Iarray.for_all
            (fun (c : X.cleanup) -> c.outcome = Ok ())
            receipt.cleanup);
        let snapshot = get (C.capture client) in
        assert (
          not
            (Snapshot.sessions snapshot
            |> Iarray.exists (fun session ->
                Session.name session = "workspace-partial")));
        let append = P.Append_new_windows { window_collision = Reject } in
        let cfg =
          config ~session:"fixture"
            [
              window "append-owned"
                [ pane (); pane ~size:(Geometry.Cells 1) (); pane () ];
            ]
        in
        let receipt = execute (plan ~collision_policy:append cfg) in
        assert (receipt.status = X.Partial && Iarray.length receipt.cleanup = 2);
        assert (
          Iarray.for_all
            (fun (c : X.cleanup) -> c.outcome = Ok ())
            receipt.cleanup);
        let snapshot = get (C.capture client) in
        let original = Iarray.get (Snapshot.panes initial) 0 in
        assert (Snapshot.find_pane snapshot (Pane.id original) |> Option.is_some);
        let cfg = config ~session:"fixture" [ window "raced" [ pane () ] ] in
        let before = plan ~collision_policy:append cfg in
        let session =
          Snapshot.sessions snapshot
          |> Iarray.find_opt (fun session -> Session.name session = "fixture")
          |> Option.get
        in
        let concurrent =
          run
            (Operations.create_window ~name:"raced"
               ~spawn:(Spawn.make (Shell "exec cat"))
               (Session.target session))
        in
        let receipt = execute before in
        assert (receipt.status = X.Rejected (P.Window_conflict "raced"));
        assert (
          Iarray.for_all
            (fun (step : X.step) -> step.status = Skipped)
            receipt.steps);
        run (Operations.kill_window concurrent.window);
        let stale =
          plan
            (config ~session:"workspace-stale" [ window "first" [ pane () ] ])
        in
        let other =
          get (C.connect ~binary (Source.endpoint (C.source client)))
        in
        Fun.protect
          ~finally:(fun () -> ignore (get (C.close other)))
          (fun () ->
            let operation = get (W.submit other stale) in
            let receipt = get (W.await operation) in
            assert (receipt.status = X.Rejected P.Stale);
            ignore (get (W.close operation)));
        print_endline "CONTEXT_READY";
        assert (B.read_line () = "continue");
        let receipt =
          execute
            (plan
               (config ~session:"workspace-linked"
                  [
                    window "linked" [ pane (); pane () ];
                    window "kept" [ pane () ];
                  ]))
        in
        assert (receipt.status = X.Succeeded);
        let linked =
          get (C.capture client)
          |> Snapshot.sessions
          |> Iarray.find_opt (fun session ->
              Session.name session = "workspace-linked")
          |> Option.get
        in
        assert (Iarray.length (Session.windows linked) = 2);
        print_endline "CONTEXT_PASSED";
        assert (B.read_line () = "continue");
        let foreign =
          run
            (Operations.split_pane (Pane.target original)
               ~spawn:(Spawn.make (Shell "exec cat"))
               ~direction:Geometry.Below)
        in
        Printf.printf "SAFETY_READY %s\n%!"
          (Pane.Id.to_string (Pane.Target.id foreign.pane));
        assert (B.read_line () = "continue");
        let receipt =
          execute
            (plan ~collision_policy:append
               (config ~session:"fixture"
                  [
                    window "borrowed-injection"
                      [ pane (); pane ~size:(Geometry.Cells 1) (); pane () ];
                  ]))
        in
        assert (receipt.status = X.Partial);
        let snapshot = get (C.capture client) in
        assert (
          Option.is_some
            (Snapshot.find_pane snapshot (Pane.Target.id foreign.pane)));
        print_endline "SAFETY_PASSED";
        assert (B.read_line () = "continue");
        print_endline "CANCEL_READY";
        assert (B.read_line () = "continue");
        let cfg =
          config ~session:"workspace-cancel"
            [ window "first" [ pane () ]; window "skipped" [ pane () ] ]
        in
        let operation = get (W.submit client (plan cfg)) in
        B.cancel operation;
        let receipt = get (W.inspect operation) in
        assert (receipt.status = X.Interrupted);
        assert (
          Iarray.exists
            (fun (step : X.step) -> step.status = Skipped)
            receipt.steps);
        assert (
          Iarray.length receipt.cleanup = 1
          && (Iarray.get receipt.cleanup 0).outcome = Ok ());
        ignore (get (W.close operation));
        ignore (get (C.capture client));
        print_endline
          "PASS workspace execution, partial compensation, append, races, \
           stale plans, cancellation journal")
end
