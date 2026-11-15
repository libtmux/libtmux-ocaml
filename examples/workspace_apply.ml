open Libtmux
module Client = Libtmux_unix.Client
module Workspace = Libtmux_unix.Workspace
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan
module Execution = Libtmux_workspace.Execution

let checked pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let get result = checked Error.pp result

let local_version binary =
  let input = Unix.open_process_args_in binary [| binary; "-V" |] in
  let text = String.trim (input_line input) in
  if Unix.close_process_in input <> Unix.WEXITED 0 then
    failwith "tmux version discovery failed";
  String.sub text 5 (String.length text - 5)

let load path =
  let directory = Filename.dirname path in
  In_channel.with_open_bin path In_channel.input_all
  |> Libtmux_json.Workspace.of_string ~directory
  |> checked Libtmux_json.Decode_error.pp

let window_summary snapshot =
  Snapshot.windows snapshot |> Iarray.to_list
  |> List.map (fun window ->
      let panes =
        Snapshot.panes snapshot |> Iarray.to_list
        |> List.filter (fun pane ->
            Window.Id.equal (Window.id (Pane.window pane)) (Window.id window))
      in
      Printf.sprintf "%s:%d" (Window.name window) (List.length panes))
  |> List.sort compare

let () =
  let binary = if Array.length Sys.argv = 2 then Sys.argv.(1) else "tmux" in
  let config =
    load (Filename.concat (Sys.getcwd ()) "examples/workspace/project.json")
  in
  let windows = Config.windows config in
  Printf.printf "Valid workspace %S: %d windows, %d panes\n"
    (Config.session config) (Iarray.length windows)
    (Iarray.fold_left
       (fun total (window : Config.window) -> total + List.length window.panes)
       0 windows);
  let summary =
    get
      (Libtmux_unix.with_private_daemon ~binary (fun endpoint ->
           let plan =
             Plan.make ~endpoint ~version:(local_version binary) ~observed:None
               config
             |> checked Plan.pp_error
           in
           Printf.printf "Plan: %d actions\n"
             (Iarray.length (Plan.actions plan));
           let execution = get (Workspace.submit_bootstrap ~binary plan) in
           Fun.protect
             ~finally:(fun () -> get (Workspace.close execution))
             (fun () ->
               let receipt = get (Workspace.await execution) in
               if receipt.status <> Execution.Succeeded then
                 failwith "workspace did not apply; read the receipt";
               print_endline "Receipt: succeeded";
               let client = Option.get (Workspace.client execution) in
               window_summary (get (Client.capture client)))))
  in
  List.iter print_endline summary
