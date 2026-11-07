open Libtmux

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let expression =
  Expr.all
    [ Expr.Bool.is_true Pane.Fields.active; Expr.Int.ge Pane.Fields.width 1 ]

let exercise count capture =
  print_endline "READY";
  assert (read_line () = "run");
  let matches = Expr.compile expression in
  let max_clients = ref 0 in
  let allocated_before = Gc.allocated_bytes () in
  let rows =
    List.init count (fun _ ->
        let snapshot = capture () in
        max_clients :=
          max !max_clients (Iarray.length (Snapshot.clients snapshot));
        let panes = Snapshot.panes snapshot |> Iarray.to_seq in
        let declarative =
          panes |> Seq.filter matches |> Seq.map Pane.id |> List.of_seq
        in
        let native =
          panes
          |> Seq.filter (fun pane -> Pane.active pane && Pane.width pane >= 1)
          |> Seq.map Pane.id |> List.of_seq
        in
        if not (List.equal Pane.Id.equal declarative native) then
          failwith "query results differ";
        `List (List.map (fun id -> `String (Pane.Id.to_string id)) declarative))
  in
  let allocated_bytes = Gc.allocated_bytes () -. allocated_before in
  Yojson.Safe.to_channel stdout
    (`Assoc
       [
         ("results", `List rows);
         ("max_clients", `Int !max_clients);
         ("loop_allocated_bytes", `Float allocated_bytes);
       ]);
  print_newline ()

let () =
  if Array.length Sys.argv <> 5 then
    failwith "usage: capture TMUX_BINARY SOCKET_PATH BACKEND ITERATIONS";
  let count = int_of_string Sys.argv.(4) in
  if count < 1 || count > 1000 then failwith "iterations must be 1..1000";
  let endpoint = Endpoint.socket_path Sys.argv.(2) in
  if Sys.argv.(3) = "unix" then
    let module C = Libtmux_unix.Client in
    let client = get (C.connect ~binary:Sys.argv.(1) endpoint) in
    Fun.protect
      ~finally:(fun () -> get (C.close client))
      (fun () -> exercise count (fun () -> get (C.capture client)))
  else if Sys.argv.(3) = "eio" then
    Eio_main.run (fun env ->
        Eio.Switch.run (fun sw ->
            let module C = Libtmux_eio.Client in
            let client =
              get
                (C.connect ~sw ~binary:Sys.argv.(1)
                   ~process_mgr:(Eio.Stdenv.process_mgr env)
                   ~mono_clock:(Eio.Stdenv.mono_clock env)
                   endpoint)
            in
            Fun.protect
              ~finally:(fun () ->
                Eio.Cancel.protect (fun () -> get (C.close client)))
              (fun () -> exercise count (fun () -> get (C.capture client)))))
  else failwith "backend must be unix or eio"
