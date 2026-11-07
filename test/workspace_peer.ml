open Libtmux
module C = Libtmux_unix.Client
module W = Libtmux_unix.Workspace
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

let () =
  let client =
    get (C.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2)))
  in
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
      assert (receipt.status = X.Succeeded && Iarray.length receipt.cleanup = 0);
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
      assert (Iarray.length receipt.cleanup = 1);
      assert ((Iarray.get receipt.cleanup 0).outcome = Ok ());
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
      assert (receipt.status = X.Partial && Iarray.length receipt.cleanup = 1);
      (match (Iarray.get receipt.cleanup 0).resource with
      | X.Window _ -> ()
      | _ -> failwith "append compensated pre-existing session");
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
        plan (config ~session:"workspace-stale" [ window "first" [ pane () ] ])
      in
      let other =
        get (C.connect ~binary:Sys.argv.(1) (Source.endpoint (C.source client)))
      in
      Fun.protect
        ~finally:(fun () -> ignore (get (C.close other)))
        (fun () ->
          let operation = get (W.submit other stale) in
          let receipt = get (W.await operation) in
          assert (receipt.status = X.Rejected P.Stale);
          ignore (get (W.close operation)));
      print_endline "CANCEL_READY";
      assert (read_line () = "continue");
      let cfg =
        config ~session:"workspace-cancel"
          [ window "first" [ pane () ]; window "skipped" [ pane () ] ]
      in
      let operation = get (W.submit client (plan cfg)) in
      Libtmux_unix.Cancellation.with_ (fun cancel ->
          let sender =
            Domain.spawn (fun () ->
                assert (read_line () = "cancel");
                Libtmux_unix.Cancellation.cancel cancel;
                print_endline "CANCELLED_SIGNAL")
          in
          Fun.protect
            ~finally:(fun () -> Domain.join sender)
            (fun () ->
              match W.await ~cancel operation with
              | _ -> failwith "workspace cancellation did not propagate"
              | exception Libtmux_unix.Cancellation.Cancelled -> ()));
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
        "PASS workspace execution, partial compensation, append, races, stale \
         plans, cancellation journal")
