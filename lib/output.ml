type cursor = { generation : Graph.Generation.t; offset : int64 }

type reason =
  | Overflow
  | Membership_changed
  | Server_paused
  | Cancelled
  | Client_closed
  | Transport_error of Error.t

type event =
  | Data of { cursor : cursor; bytes : string }
  | Gap of { after : cursor option; lost_bytes : int option; reason : reason }
  | End of reason

type wait_error = Ended of reason | Failure of Error.t

let reason_pp formatter = function
  | Overflow -> Format.pp_print_string formatter "subscriber queue overflow"
  | Membership_changed ->
      Format.pp_print_string formatter "pane coverage or layout changed"
  | Server_paused -> Format.pp_print_string formatter "tmux paused pane output"
  | Cancelled -> Format.pp_print_string formatter "subscription cancelled"
  | Client_closed -> Format.pp_print_string formatter "client closed"
  | Transport_error error -> Error.pp formatter error
