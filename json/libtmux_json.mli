(** Pure, bounded interchange for the [libtmux.filter/1] scalar pane subset. *)

module Decode_error : sig
  type category =
    | Syntax
    | Limit
    | Unknown
    | Wrong_type
    | Out_of_range
    | Unsupported

  type t = { pointer : string; category : category; message : string }

  val pp : Format.formatter -> t -> unit
end

module Expr : sig
  val decode :
    'a Libtmux.Model.t ->
    Yojson.Safe.t ->
    ('a Libtmux.Expr.t, Decode_error.t) result
  (** Validate the supplied tree, including duplicate properties, before typed
      construction. Only the shared scalar pane registry and Boolean composition
      are accepted. Java regex, relationships and native extension fields return
      [Unsupported]. Numbers must fit signed 32-bit integers. *)

  val of_string :
    'a Libtmux.Model.t -> string -> ('a Libtmux.Expr.t, Decode_error.t) result
  (** Enforce 64 KiB and 32 JSON nesting levels before parsing; require valid
      UTF-8 JSON. Expressions have at most 1,024 nodes and membership lists at
      most 256 values. Errors include a JSON pointer, never the whole input. *)

  val encode :
    'a Libtmux.Model.t ->
    'a Libtmux.Expr.t ->
    (Yojson.Safe.t, Decode_error.t) result

  val to_string :
    'a Libtmux.Model.t -> 'a Libtmux.Expr.t -> (string, Decode_error.t) result
  (** Apply the same bounds and subset when encoding. Text with invalid UTF-8
      has no representation in this schema. These functions perform no I/O. *)
end
