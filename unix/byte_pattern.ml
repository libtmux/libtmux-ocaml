open Libtmux

type t = { text : string; prefix : int array; mutable matched : int }

let validate text =
  if text = "" || String.length text > 65_536 then
    Runtime_io.fail (Error.Invalid_input "text must contain 1..65536 bytes")

let create text =
  validate text;
  let prefix = Array.make (String.length text) 0 in
  let matched = ref 0 in
  for index = 1 to String.length text - 1 do
    while !matched > 0 && text.[!matched] <> text.[index] do
      matched := prefix.(!matched - 1)
    done;
    if text.[!matched] = text.[index] then incr matched;
    prefix.(index) <- !matched
  done;
  { text; prefix; matched = 0 }

let feed pattern bytes =
  let rec loop index =
    if index = String.length bytes then None
    else (
      while
        pattern.matched > 0 && pattern.text.[pattern.matched] <> bytes.[index]
      do
        pattern.matched <- pattern.prefix.(pattern.matched - 1)
      done;
      if pattern.text.[pattern.matched] = bytes.[index] then
        pattern.matched <- pattern.matched + 1;
      if pattern.matched = String.length pattern.text then (
        pattern.matched <- pattern.prefix.(pattern.matched - 1);
        Some index)
      else loop (index + 1))
  in
  loop 0

let contains pattern bytes =
  pattern.matched <- 0;
  Option.is_some (feed pattern bytes)
