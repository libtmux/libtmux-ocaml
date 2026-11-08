open Libtmux
open Runtime_io
module C = Connection

let format_text text =
  if String.length text > 65_536 then
    fail (Error.Capacity { resource = "format argument bytes"; limit = 65_536 });
  String.to_seq text
  |> Seq.flat_map (fun c ->
      if c = '#' then List.to_seq [ '#'; '#' ] else Seq.return c)
  |> String.of_seq

let session c target =
  C.target c (Session.Target.source target);
  Session.Id.to_string (Session.Target.id target)

let window c target =
  C.target c (Window.Target.source target);
  Window.Id.to_string (Window.Target.id target)

let pane c target =
  C.target c (Pane.Target.source target);
  Pane.Id.to_string (Pane.Target.id target)

let client_name c target =
  C.target c (Client_name.source target);
  let name = Client_name.to_string target in
  if name = "" then fail (Error.Invalid_input "client name must be nonempty");
  (* tmux strips exactly one trailing colon from a client target. *)
  name ^ ":"

let index value =
  if value < 0 || value > 2_147_483_647 then
    fail (Error.Invalid_input "window index must be within 0..2147483647");
  Int.to_string value

let at c target number = session c target ^ ":" ^ index number

let dimension value =
  if value < 1 || value > 10_000 then
    fail (Error.Invalid_input "dimension must be within 1..10000 cells");
  Int.to_string value

let size = function
  | Geometry.Cells value -> dimension value
  | Percent value ->
      if value < 1 || value > 99 then
        fail (Error.Invalid_input "split percentage must be within 1..99");
      Int.to_string value ^ "%"

let direction = function
  | Geometry.Left -> [ "-h"; "-b" ]
  | Right -> [ "-h" ]
  | Above -> [ "-v"; "-b" ]
  | Below -> [ "-v" ]

let optional flag convert = function
  | None -> []
  | Some value -> [ flag; convert value ]

let geometry width height =
  if width = None && height = None then
    fail (Error.Invalid_input "resize requires a width or height");
  optional "-x" dimension width @ optional "-y" dimension height

let env_name text =
  let first = function 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false in
  if
    text = ""
    || (not (first text.[0]))
    || not (String.for_all (fun c -> first c || (c >= '0' && c <= '9')) text)
  then fail (Error.Invalid_input "environment name must be an ASCII identifier")

let environment_scope c = function
  | Environment.Global -> [ "-g" ]
  | Session target -> [ "-t"; session c target ]

let option_scope c = function
  | Options.Server -> [ "-s" ]
  | Global_sessions -> [ "-g" ]
  | Global_windows -> [ "-g"; "-w" ]
  | Session target -> [ "-t"; session c target ]
  | Window target -> [ "-w"; "-t"; window c target ]
  | Pane target -> [ "-p"; "-t"; pane c target ]

let option_descriptor ?(hook = false) c scope name =
  let descriptor = get (Options.describe ~version:c.C.version name) in
  let kind =
    match scope with
    | Options.Server -> `Server
    | Global_sessions | Session _ -> `Session
    | Global_windows | Window _ -> `Window
    | Pane _ -> `Pane
  in
  if not (List.mem kind descriptor.scopes) then
    fail (Error.Invalid_input "option does not belong to the selected scope");
  if descriptor.hook <> hook && not (hook && String.starts_with ~prefix:"@" name)
  then
    fail
      (Error.Invalid_input "option and hook operations require their own kind");
  descriptor

let option_name descriptor number =
  match number with
  | None -> descriptor.Options.name
  | Some value ->
      if not descriptor.array then
        fail (Error.Invalid_input "option is not an array");
      descriptor.name ^ "[" ^ index value ^ "]"

let option_value descriptor value =
  match (descriptor.Options.kind, value) with
  | Text, Options.Text text
  | Choice, Choice text
  | Key, Key text
  | Colour, Colour text
  | Commands, Commands text ->
      text
  | Number, Integer value -> Int64.to_string value
  | Flag, Bool value -> if value then "on" else "off"
  | _ -> fail (Error.Invalid_input "option scalar type mismatch")

let hook_commands commands =
  if commands = [] then
    fail
      (Error.Invalid_input "hook requires commands; use remove_hook to clear it");
  let buffer = Buffer.create 64 in
  let rec render count = function
    | [] -> Buffer.contents buffer
    | (command : Hook.command) :: rest ->
        if count = 64 then
          fail (Error.Capacity { resource = "hook commands"; limit = 64 });
        if count <> 0 then Buffer.add_string buffer " ; ";
        let limit = 65_536 - Buffer.length buffer in
        (match
           C.P.Command.render ~max_bytes:limit command.name command.arguments
         with
        | Ok text -> Buffer.add_string buffer text
        | Error (C.P.Malformed message) -> fail (Error.Invalid_input message)
        | Error (C.P.Limit _) ->
            fail
              (Error.Capacity
                 { resource = "hook command bytes"; limit = 65_536 }));
        render (count + 1) rest
  in
  render 0 commands

let spawn (value : Spawn.t) =
  let cwd =
    optional "-c"
      (fun path ->
        if path = "" || path.[0] <> '/' then
          fail (Error.Invalid_input "working directory must be absolute");
        format_text path)
      value.cwd
  in
  let rec environment seen count bytes = function
    | [] -> []
    | (name, value) :: rest ->
        if count = 256 then
          fail (Error.Capacity { resource = "spawn environment"; limit = 256 });
        if String.length name > 65_536 || String.length value > 65_536 then
          fail
            (Error.Capacity
               { resource = "environment field bytes"; limit = 65_536 });
        let length = String.length name + String.length value + 1 in
        if length > 1_048_576 - bytes then
          fail
            (Error.Capacity
               { resource = "environment bytes"; limit = 1_048_576 });
        env_name name;
        if List.mem name seen then
          fail (Error.Invalid_input "duplicate environment variable");
        "-e"
        :: (name ^ "=" ^ value)
        :: environment (name :: seen) (count + 1) (bytes + length) rest
  in
  let arguments =
    match value.command with
    | Spawn.Default -> []
    | Shell command ->
        if command = "" then
          fail (Error.Invalid_input "shell command must be nonempty");
        [ command ]
    | Exec { program; args } ->
        if program = "" || program.[0] = '-' then
          fail
            (Error.Invalid_input
               "executable must be nonempty and not start with '-'");
        let rec bounded count = function
          | [] -> ()
          | _ :: rest ->
              if count = 4096 then
                fail
                  (Error.Capacity
                     { resource = "program arguments"; limit = 4096 });
              bounded (count + 1) rest
        in
        bounded 0 args;
        if args = [] then
          [ "/bin/sh"; "-c"; "exec \"$@\""; "libtmux-exec"; program ]
        else program :: args
  in
  (cwd @ environment [] 0 0 value.environment, arguments)

let layout = function
  | Layout.Even_horizontal -> "even-horizontal"
  | Even_vertical -> "even-vertical"
  | Main_horizontal -> "main-horizontal"
  | Main_vertical -> "main-vertical"
  | Tiled -> "tiled"
  | Custom value ->
      if
        value = ""
        || not
             (String.for_all
                (fun c -> String.contains "0123456789abcdefABCDEFx,{}[]" c)
                value)
      then fail (Error.Invalid_input "invalid custom layout characters");
      value

let mutation c = function
  | Command.Switch_client_at { client; session = target; update_environment } ->
      ( "switch-client",
        [ "-c"; client_name c client; "-t"; session c target ]
        @ if update_environment then [] else [ "-E" ] )
  | Request_detach_client_at client ->
      ("detach-client", [ "-t"; client_name c client ])
  | Refresh_client_at (client, status_only) ->
      ( "refresh-client",
        [ "-t"; client_name c client ] @ if status_only then [ "-S" ] else [] )
  | Resize_control_client_at { client; width; height } ->
      ( "refresh-client",
        [
          "-t";
          client_name c client;
          "-C";
          dimension width ^ "x" ^ dimension height;
        ] )
  | Command.Kill_session target -> ("kill-session", [ "-t"; session c target ])
  | Kill_window target -> ("kill-window", [ "-t"; window c target ])
  | Kill_pane target -> ("kill-pane", [ "-t"; pane c target ])
  | Select_window_at (target, number) ->
      ("select-window", [ "-t"; at c target number ])
  | Unlink_window_at { session; index; allow_kill } ->
      ( "unlink-window",
        [ "-t"; at c session index ] @ if allow_kill then [ "-k" ] else [] )
  | Link_window { window = target; session; index } ->
      ("link-window", [ "-d"; "-s"; window c target; "-t"; at c session index ])
  | Move_window_at { from_session; from_index; session; index } ->
      ( "move-window",
        [ "-d"; "-s"; at c from_session from_index; "-t"; at c session index ]
      )
  | Select_pane target -> ("select-pane", [ "-t"; pane c target ])
  | Set_pane_title (target, title) ->
      ("select-pane", [ "-t"; pane c target; "-T"; format_text title ])
  | Resize_pane { pane = target; width; height } ->
      ("resize-pane", [ "-t"; pane c target ] @ geometry width height)
  | Resize_window { window = target; width; height } ->
      ("resize-window", [ "-t"; window c target ] @ geometry width height)
  | Select_layout (target, value) ->
      ("select-layout", [ "-t"; window c target; "--"; layout value ])
  | Cycle_layout (target, value) ->
      ( (match value with
        | `Next -> "next-layout"
        | `Previous -> "previous-layout"),
        [ "-t"; window c target ] )
  | Move_pane { pane = target; beside; direction = side; size = extent } ->
      ( "move-pane",
        [ "-d"; "-s"; pane c target; "-t"; pane c beside ]
        @ direction side @ optional "-l" size extent )
  | Swap_panes (target, other) ->
      ("swap-pane", [ "-d"; "-s"; pane c target; "-t"; pane c other ])
  | Rotate_panes (target, value) ->
      ( "rotate-window",
        [ "-t"; window c target ]
        @ if value = `Backward then [ "-D" ] else [ "-U" ] )
  | Zoom_pane target -> ("resize-pane", [ "-Z"; "-t"; pane c target ])
  | Respawn_pane { pane = target; spawn = spec; kill_running } ->
      let flags, args = spawn spec in
      ( "respawn-pane",
        [ "-t"; pane c target ]
        @ (if kill_running then [ "-k" ] else [])
        @ flags @ [ "--" ] @ args )
  | Clear_history target -> ("clear-history", [ "-t"; pane c target ])
  | Set_environment { scope; name; value; hidden } ->
      env_name name;
      ( "set-environment",
        environment_scope c scope
        @ (if hidden then [ "-h" ] else [])
        @ [ "--"; name; value ] )
  | Unset_environment (scope, name) ->
      env_name name;
      ("set-environment", environment_scope c scope @ [ "-u"; "--"; name ])
  | Remove_environment (scope, name) ->
      env_name name;
      ("set-environment", environment_scope c scope @ [ "-r"; "--"; name ])
  | Set_option { scope; name; index = number; value; append } ->
      let descriptor = option_descriptor c scope name in
      let name = option_name descriptor number in
      if descriptor.array && number = None && not append then
        fail
          (Error.Invalid_input
             "array assignment requires an index or explicit append");
      if append && descriptor.kind <> Text && descriptor.kind <> Commands then
        fail (Error.Invalid_input "append requires text or commands");
      ( "set-option",
        option_scope c scope
        @ (if append then [ "-a" ] else [])
        @ [ "--"; name; option_value descriptor value ] )
  | Unset_option (scope, name, number) ->
      let descriptor = option_descriptor c scope name in
      ( "set-option",
        option_scope c scope @ [ "-u"; "--"; option_name descriptor number ] )
  | Clear_option_array (scope, name) ->
      let descriptor = option_descriptor c scope name in
      if not descriptor.array then
        fail (Error.Invalid_input "option is not an array");
      ("set-option", option_scope c scope @ [ "--"; name; "" ])
  | Set_hook { scope; name; index = number; commands; append } ->
      let descriptor = option_descriptor ~hook:true c scope name in
      if (not descriptor.array) && append then
        fail
          (Error.Invalid_input "named user hooks require complete replacement");
      ( "set-hook",
        option_scope c scope
        @ (if append then [ "-a" ] else [])
        @ [ "--"; option_name descriptor number; hook_commands commands ] )
  | Remove_hook (scope, name, number) ->
      let descriptor = option_descriptor ~hook:true c scope name in
      ( "set-hook",
        option_scope c scope @ [ "-u"; "--"; option_name descriptor number ] )
  | Run_hook (scope, name) ->
      if String.starts_with ~prefix:"@" name then
        fail
          (Error.Unsupported
             "tmux does not report named user-hook parse failures");
      ignore (option_descriptor ~hook:true c scope name);
      (match scope with
      | Options.Server | Global_sessions | Global_windows ->
          fail
            (Error.Invalid_input
               "running a hook requires a session, window or pane context")
      | _ -> ());
      ("set-hook", option_scope c scope @ [ "-R"; "--"; name ])

let creation_fields =
  [ "session_id"; "window_id"; "pane_id"; "window_index"; "pane_index" ]

let creation_flags () =
  [ "-d"; "-P"; "-F"; protocol (C.P.Metadata.format creation_fields) ]

let create : type a. C.t -> a Command.view -> string * string list =
 fun c command ->
  match command with
  | Create_session { name; window_name; width; height; spawn = spec } ->
      if name = "" then
        fail (Error.Invalid_input "session name must be nonempty");
      let flags, args = spawn spec in
      ( "new-session",
        creation_flags ()
        @ [
            "-s";
            format_text name;
            "-x";
            dimension width;
            "-y";
            dimension height;
          ]
        @ optional "-n" format_text window_name
        @ flags @ [ "--" ] @ args )
  | Create_window { session = target; index = number; name; spawn = spec } ->
      let flags, args = spawn spec in
      let target =
        session c target ^ ":" ^ Option.fold ~none:"" ~some:index number
      in
      ( "new-window",
        creation_flags () @ [ "-t"; target ]
        @ optional "-n" format_text name
        @ flags @ [ "--" ] @ args )
  | Split_pane { pane = target; direction = side; size = extent; spawn = spec }
    ->
      let flags, args = spawn spec in
      ( "split-window",
        creation_flags ()
        @ [ "-t"; pane c target ]
        @ direction side @ optional "-l" size extent @ flags @ [ "--" ] @ args
      )
  | Break_pane { pane = target; session; index; name } ->
      ( "break-pane",
        creation_flags ()
        @ [ "-s"; pane c target; "-t"; at c session index ]
        @ optional "-n" format_text name )
  | _ -> assert false

let created c body =
  try
    let rows =
      protocol (C.P.Metadata.decode ~dialect:c.C.dialect ~fields:5 body)
    in
    match C.singleton rows with
    | [ session; window; pane; window_index; pane_index ] ->
        Created.
          {
            session =
              Session.Target.of_id ~source:c.source
                (get (Session.Id.of_string session));
            window =
              Window.Target.of_id ~source:c.source
                (get (Window.Id.of_string window));
            pane =
              Pane.Target.of_id ~source:c.source (get (Pane.Id.of_string pane));
            window_index = C.integer window_index;
            pane_index = C.integer pane_index;
          }
    | _ -> fail (Error.Malformed_data "creation response shape")
  with Failure cause ->
    Cleanup.protect
      ~finally:(fun () -> C.close c)
      (fun () ->
        fail
          (Error.Outcome_unknown
             (Format.asprintf "creation response: %a" Error.pp cause)))
