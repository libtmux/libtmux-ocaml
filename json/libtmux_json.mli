(** Pure, bounded query and workspace JSON interchange. *)

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

(** Structured native failures for JSON consumers. *)
module Error : sig
  val encode : Libtmux.Error.t -> Yojson.Safe.t
  (** Return a stable [code], bounded [message], [message_truncated] flag and
      relevant operation, resource or target metadata. Messages and text
      attributes retain at most 4096 bytes; invalid UTF-8 uses the tagged hex
      representation described by {!Workspace.encode_receipt}. No I/O. *)
end

(** Validate workspace documents and describe plans and retained execution.
    Preview output never supplies executable targets. *)
module Workspace : sig
  val decode :
    directory:string ->
    Yojson.Safe.t ->
    (Libtmux_workspace.Config.t, Decode_error.t) result

  val of_string :
    directory:string ->
    string ->
    (Libtmux_workspace.Config.t, Decode_error.t) result
  (** Decode [libtmux.workspace/1] with the query codec's 64 KiB, UTF-8 and
      32-level JSON bounds. Reject duplicate and unknown properties, invalid
      argv/shell combinations and configuration errors. [directory] is the
      absolute document directory; these functions perform no filesystem I/O. *)

  val encode_plan :
    Libtmux_workspace.Plan.t -> (Yojson.Safe.t, Decode_error.t) result
  (** Describe [libtmux.workspace-plan/1] without I/O. The advisory preview
      contains command argv, cwd and environment names, excluding environment
      values, option values and startup text. It is not an execution script. *)

  val encode_receipt :
    Libtmux_workspace.Execution.receipt ->
    (Yojson.Safe.t, Decode_error.t) result
  (** Describe [libtmux.workspace-receipt/1] with ordered steps, outcome index
      lists, creation IDs, unbound hints and per-pane cleanup. Diagnostic
      messages are limited to 4096 bytes with an explicit truncation flag;
      command payloads are omitted.

      Both output schemas have a 4 MiB bound. Invalid UTF-8 values use
      [{"encoding":"hex","bytes":"..."}] instead of losing bytes. Imported IDs
      and hints never establish a connection binding. *)
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
