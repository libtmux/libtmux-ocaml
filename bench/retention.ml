open Libtmux
module Client = Libtmux_unix.Client

let get = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" Error.pp error)

let live_words () =
  Gc.full_major ();
  (Gc.stat ()).live_words

let pane snapshot = Iarray.get (Snapshot.panes snapshot) 0

let measure client ~captures ~windows ~keep ~project =
  let capture () =
    let snapshot = get (Client.capture client) in
    if
      Iarray.length (Snapshot.sessions snapshot) <> 1
      || Iarray.length (Snapshot.windows snapshot) <> windows
      || Iarray.length (Snapshot.panes snapshot) <> windows
      || Iarray.length (Snapshot.clients snapshot) <> 1
    then failwith "captured topology differs from fixture";
    snapshot
  in
  (* Warm protocol buffers before comparing live heap; retain no warm observation. *)
  ignore (Sys.opaque_identity (capture ()));
  let retained = ref [] in
  let baseline_words = live_words () in
  let allocated_before = Gc.allocated_bytes () in
  for _ = 1 to captures do
    let value = project (capture ()) in
    match keep with
    | `All -> retained := value :: !retained
    | `Latest -> retained := [ value ]
    | `None -> ()
  done;
  let allocated_bytes = Gc.allocated_bytes () -. allocated_before in
  let retained_words = live_words () in
  (* The measured roots must stay live through the collection above. *)
  let retained_values = List.length (Sys.opaque_identity !retained) in
  retained := [];
  let released_words = live_words () in
  let bytes words = words * (Sys.word_size / 8) in
  `Assoc
    [
      ("baseline_live_bytes", `Int (bytes baseline_words));
      ("retained_live_bytes", `Int (bytes retained_words));
      ("released_live_bytes", `Int (bytes released_words));
      ("retained_delta_bytes", `Int (bytes (retained_words - baseline_words)));
      ("released_delta_bytes", `Int (bytes (released_words - baseline_words)));
      ("retained_values", `Int retained_values);
      ("loop_allocated_bytes", `Float allocated_bytes);
    ]

let () =
  if Array.length Sys.argv <> 6 then
    failwith "usage: retention TMUX_BINARY SOCKET_PATH MODE CAPTURES WINDOWS";
  let mode = Sys.argv.(3) in
  let captures = int_of_string Sys.argv.(4) in
  let windows = int_of_string Sys.argv.(5) in
  if captures < 1 || captures > 512 || windows < 1 || windows > 128 then
    failwith "captures must be 1..512; windows must be 1..128";
  let client =
    get
      (Client.connect ~binary:Sys.argv.(1) (Endpoint.socket_path Sys.argv.(2)))
  in
  let result =
    Fun.protect
      ~finally:(fun () -> get (Client.close client))
      (fun () ->
        let run ~keep ~project =
          measure client ~captures ~windows ~keep ~project
        in
        match mode with
        | "snapshots" -> run ~keep:`All ~project:Fun.id
        | "panes" -> run ~keep:`All ~project:pane
        | "latest-pane" -> run ~keep:`Latest ~project:pane
        | "targets" ->
            run ~keep:`All ~project:(fun snapshot ->
                Pane.target (pane snapshot))
        | "summaries" ->
            run ~keep:`All ~project:(fun snapshot ->
                let value = pane snapshot in
                ( Pane.Id.to_string (Pane.id value),
                  Pane.current_command value,
                  Pane.current_path value ))
        | "discard" -> run ~keep:`None ~project:(fun _ -> ())
        | _ -> failwith "unknown retention mode")
  in
  Yojson.Safe.to_channel stdout result;
  print_newline ()
