open Libtmux
module Config = Libtmux_workspace.Config
module Plan = Libtmux_workspace.Plan

let checked pp = function
  | Ok value -> value
  | Error error -> failwith (Format.asprintf "%a" pp error)

let () =
  let spawn = Spawn.make (Exec { program = "cat"; args = [] }) in
  let config =
    Config.make ~directory:"/srv/project" ~session:"project"
      [
        Config.window ~name:"editor"
          [
            Config.pane ~spawn ();
            Config.pane ~spawn ~direction:Geometry.Right ();
          ];
        Config.window ~name:"logs" [ Config.pane ~spawn () ];
      ]
    |> checked Config.pp_error
  in
  let plan =
    Plan.make
      ~endpoint:(Endpoint.socket_path "/srv/project/tmux.sock")
      ~version:"3.8" ~observed:None config
    |> checked Plan.pp_error
  in
  Printf.printf "%s: %d windows, %d actions\n" (Config.session config)
    (Iarray.length (Config.windows config))
    (Iarray.length (Plan.actions plan))
