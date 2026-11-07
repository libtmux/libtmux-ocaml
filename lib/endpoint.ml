type kind = Named_socket of string | Socket_path of string
type t = kind

let named_socket name =
  if
    String.length name = 0
    || String.contains name '\000'
    || String.contains name '/'
  then invalid_arg "Endpoint.named_socket: expected a nonempty socket name";
  Named_socket name

let socket_path path =
  if String.length path = 0 || path.[0] <> '/' || String.contains path '\000'
  then invalid_arg "Endpoint.socket_path: expected an absolute socket path";
  Socket_path path

let kind endpoint = endpoint

let equal left right =
  match (left, right) with
  | Named_socket a, Named_socket b | Socket_path a, Socket_path b ->
      String.equal a b
  | Named_socket _, Socket_path _ | Socket_path _, Named_socket _ -> false

let pp formatter = function
  | Named_socket name -> Format.fprintf formatter "named socket %S" name
  | Socket_path path -> Format.fprintf formatter "socket path %S" path
