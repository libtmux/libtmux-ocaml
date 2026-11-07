external pidfd_open : int -> Unix.file_descr = "libtmux_pidfd_open"
external pidfd_alive : Unix.file_descr -> bool = "libtmux_pidfd_alive"
external monotonic_ns : unit -> int64 = "libtmux_monotonic_ns"
external random_bytes : unit -> string = "libtmux_random_bytes"

let nonce () =
  let bytes = random_bytes () in
  let digits = "0123456789abcdef" in
  String.init 64 (fun index ->
      let byte = Char.code bytes.[index / 2] in
      digits.[if index mod 2 = 0 then byte lsr 4 else byte land 15])

let now () = Int64.to_float (monotonic_ns ()) /. 1e9
