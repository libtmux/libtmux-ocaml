type t =
  | Invalid_input of string
  | Malformed_data of string
  | Capture_raced of string
  | Unsupported_version of string
  | Unsupported_binding of string
  | Unsupported_capture_hooks
  | Unsupported of string
  | Closed
  | Disconnected of string
  | Filesystem of { operation : string; message : string }
  | Wrong_domain
  | Busy
  | Capacity of { resource : string; limit : int }
  | Stale_target
  | No_such_entity of { kind : string; id : string }
  | Command_failed of { command : string; message : string }
  | Deadline_exceeded
  | Not_started
  | Outcome_unknown of string

let pp formatter = function
  | Invalid_input message ->
      Format.fprintf formatter "invalid input: %s" message
  | Malformed_data message ->
      Format.fprintf formatter "malformed data: %s" message
  | Capture_raced message ->
      Format.fprintf formatter "capture changed: %s" message
  | Unsupported_version version ->
      Format.fprintf formatter "unsupported tmux version: %s" version
  | Unsupported_binding message ->
      Format.fprintf formatter "unsupported server binding: %s" message
  | Unsupported_capture_hooks ->
      Format.pp_print_string formatter "capture hooks may alter the transfer"
  | Unsupported feature -> Format.fprintf formatter "unsupported: %s" feature
  | Closed -> Format.pp_print_string formatter "client is closed"
  | Disconnected message -> Format.fprintf formatter "disconnected: %s" message
  | Filesystem { operation; message } ->
      Format.fprintf formatter "filesystem %s: %s" operation message
  | Wrong_domain ->
      Format.pp_print_string formatter "client belongs to another domain"
  | Busy ->
      Format.pp_print_string formatter "client already has an active caller"
  | Capacity { resource; limit } ->
      Format.fprintf formatter "%s capacity reached (%d)" resource limit
  | Stale_target ->
      Format.pp_print_string formatter
        "target belongs to another connection generation"
  | No_such_entity { kind; id } -> Format.fprintf formatter "no %s %s" kind id
  | Command_failed { command; message } ->
      Format.fprintf formatter "%s: %s" command message
  | Deadline_exceeded -> Format.pp_print_string formatter "deadline exceeded"
  | Not_started ->
      Format.pp_print_string formatter "operation was cancelled before writing"
  | Outcome_unknown message ->
      Format.fprintf formatter "outcome unknown: %s" message
