open Libtmux
module Client = Libtmux_eio.Client
module Operation = Libtmux_eio.Operation

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let protect ~finally use =
  match use () with
  | value ->
      Eio.Cancel.protect finally;
      value
  | exception error ->
      let backtrace = Printexc.get_raw_backtrace () in
      (try Eio.Cancel.protect finally
       with cleanup ->
         Format.eprintf "cleanup failed: %s@." (Printexc.to_string cleanup));
      Printexc.raise_with_backtrace error backtrace

let elapsed clock start =
  Mtime.span start (Eio.Time.Mono.now clock) |> Mtime.Span.to_float_ns
  |> fun ns -> ns /. 1e9

let requests clock client session count concurrency =
  let allocated = Gc.allocated_bytes () in
  let started = Eio.Time.Mono.now clock in
  let rows =
    List.init count Fun.id
    |> Eio.Fiber.List.map ~max_fibers:concurrency (fun index ->
        let name = Printf.sprintf "@control-bench-%04d" index in
        let value = Printf.sprintf "value-%04d" index in
        let command =
          Operations.set_option (Options.Session session) ~name
            (Options.Text value)
        in
        let start = Eio.Time.Mono.now clock in
        let operation = get (Client.submit client command) in
        let admission_seconds = elapsed clock start in
        get (Client.await operation);
        let seconds = elapsed clock start in
        (match get (Operation.inspect operation) with
        | Operation.Finished (Ok ()) -> ()
        | _ -> failwith "operation has no completed outcome");
        `Assoc
          [
            ("index", `Int index);
            ("operation_id", `String (Operation.id operation));
            ("name", `String name);
            ("value", `String value);
            ("admission_seconds", `Float admission_seconds);
            ("seconds", `Float seconds);
          ])
  in
  `Assoc
    [
      ("seconds", `Float (elapsed clock started));
      ("loop_allocated_bytes", `Float (Gc.allocated_bytes () -. allocated));
      ("rows", `List rows);
    ]

let barrier input name =
  print_endline name;
  assert (Eio.Buf_read.line input = "continue")

let () =
  if Array.length Sys.argv <> 5 then
    failwith "usage: control TMUX_BINARY SOCKET REQUESTS CONCURRENCY";
  let count = int_of_string Sys.argv.(3)
  and concurrency = int_of_string Sys.argv.(4) in
  if count < 1 || count > 512 || concurrency < 1 || concurrency > 32 then
    failwith "requests must be 1..512; concurrency must be 1..32";
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.mono_clock env in
  let client =
    get
      (Client.connect ~sw ~binary:Sys.argv.(1)
         ~process_mgr:(Eio.Stdenv.process_mgr env)
         ~mono_clock:clock
         (Endpoint.socket_path Sys.argv.(2)))
  in
  let result =
    protect
      ~finally:(fun () -> get (Client.close client))
      (fun () ->
        let snapshot = get (Client.capture client) in
        if
          Iarray.length (Snapshot.sessions snapshot) <> 1
          || Iarray.length (Snapshot.windows snapshot) <> 1
          || Iarray.length (Snapshot.panes snapshot) <> 1
          || Iarray.length (Snapshot.clients snapshot) <> 1
        then failwith "captured topology differs from fixture";
        let session =
          Session.target (Iarray.get (Snapshot.sessions snapshot) 0)
        in
        get
          (Client.set_option client (Options.Session session)
             ~name:"@control-warmup" (Options.Text "ready"));
        let input = Eio.Buf_read.of_flow ~max_size:64 (Eio.Stdenv.stdin env) in
        barrier input "READY";
        let result = requests clock client session count concurrency in
        barrier input "DONE";
        result)
  in
  Yojson.Safe.to_channel stdout result;
  print_newline ()
