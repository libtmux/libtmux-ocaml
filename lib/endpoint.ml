type kind = Named_socket of string | Socket_path of string
type t = kind

let named_socket name =
  if
    String.length name = 0
    || name = "." || name = ".."
    || String.contains name '\000'
    || String.contains name '/'
  then invalid_arg "Endpoint.named_socket: expected a nonempty socket name";
  Named_socket name

let socket_path path =
  if String.length path = 0 || path.[0] <> '/' || String.contains path '\000'
  then invalid_arg "Endpoint.socket_path: expected an absolute socket path";
  Socket_path path

let is_space = function
  | ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true
  | _ -> false

let present value = if String.for_all is_space value then None else Some value

let before_comma value =
  match String.index_opt value ',' with
  | None -> value
  | Some index -> String.sub value 0 index

let resolve_path ~cwd ~label path =
  if String.length path = 0 || String.contains path '\000' then
    invalid_arg ("Endpoint.from_env: invalid " ^ label);
  let absolute =
    if Filename.is_relative path then Filename.concat (cwd ()) path else path
  in
  socket_path absolute

let from_env ?(getenv = Sys.getenv_opt) ?cwd () =
  let check_cwd dir =
    if String.length dir = 0 || dir.[0] <> '/' || String.contains dir '\000'
    then invalid_arg "Endpoint.from_env: expected an absolute cwd";
    dir
  in
  Option.iter (fun dir -> ignore (check_cwd dir)) cwd;
  let cwd () =
    match cwd with
    | Some dir -> check_cwd dir
    | None -> check_cwd (Sys.getcwd ())
  in
  match Option.bind (getenv "LIBTMUX_SOCKET_PATH") present with
  | Some path -> resolve_path ~cwd ~label:"LIBTMUX_SOCKET_PATH" path
  | None -> (
      match Option.bind (getenv "LIBTMUX_SOCKET") present with
      | Some name -> (
          try named_socket name
          with Invalid_argument _ ->
            invalid_arg "Endpoint.from_env: invalid LIBTMUX_SOCKET")
      | None -> (
          match
            Option.bind (getenv "TMUX") (fun raw -> present (before_comma raw))
          with
          | Some path -> resolve_path ~cwd ~label:"TMUX" path
          | None -> Named_socket "default"))

let kind endpoint = endpoint

let equal left right =
  match (left, right) with
  | Named_socket a, Named_socket b | Socket_path a, Socket_path b ->
      String.equal a b
  | Named_socket _, Socket_path _ | Socket_path _, Named_socket _ -> false

let pp formatter = function
  | Named_socket name -> Format.fprintf formatter "named socket %S" name
  | Socket_path path -> Format.fprintf formatter "socket path %S" path
