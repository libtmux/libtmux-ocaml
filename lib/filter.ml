module Field = struct
  type _ kind = Bool : bool kind | Int : int kind | Text : string kind

  type ('entity, 'value) t = {
    name : string;
    kind : 'value kind;
    get : 'entity -> 'value;
  }

  type 'entity packed = Pack : ('entity, 'value) t -> 'entity packed

  let name field = field.name
  let kind field = field.kind
  let get field = field.get
end

module Relation = struct
  module Many = struct
    type ('parent, 'child) t = {
      name : string;
      get : 'parent -> 'child Iarray.t;
    }

    let name relation = relation.name
  end

  module One = struct
    type ('parent, 'child) t = { name : string; get : 'parent -> 'child }

    let name relation = relation.name
  end

  module Optional = struct
    type ('parent, 'child) t = { name : string; get : 'parent -> 'child option }

    let name relation = relation.name
  end
end

module Expr = struct
  type _ comparison =
    | Bool_equal : bool -> bool comparison
    | Int_equal : int -> int comparison
    | Int_lt : int -> int comparison
    | Int_le : int -> int comparison
    | Int_gt : int -> int comparison
    | Int_ge : int -> int comparison
    | Int_in : int list -> int comparison
    | Text_equal : string -> string comparison
    | Text_starts_with : string -> string comparison
    | Text_ends_with : string -> string comparison
    | Text_contains : string -> string comparison
    | Text_in : string list -> string comparison

  type 'a t = { node : 'a view }

  and 'a view =
    | Compare : ('a, 'v) Field.t * 'v comparison -> 'a view
    | All of 'a t list
    | Any of 'a t list
    | Not of 'a t
    | Related_any : ('a, 'b) Relation.Many.t * 'b t -> 'a view
    | Related_all : ('a, 'b) Relation.Many.t * 'b t -> 'a view
    | Related_none : ('a, 'b) Relation.Many.t * 'b t -> 'a view
    | Related_one : ('a, 'b) Relation.One.t * 'b t -> 'a view
    | Related_optional : ('a, 'b) Relation.Optional.t * 'b t -> 'a view
    | Absent : ('a, 'b) Relation.Optional.t -> 'a view

  let view expression = expression.node
  let all expressions = { node = All expressions }
  let any expressions = { node = Any expressions }
  let not_ expression = { node = Not expression }

  module Bool = struct
    let equal field value = { node = Compare (field, Bool_equal value) }
    let is_true field = equal field true
    let is_false field = equal field false
  end

  module Int = struct
    let equal field value = { node = Compare (field, Int_equal value) }
    let lt field value = { node = Compare (field, Int_lt value) }
    let le field value = { node = Compare (field, Int_le value) }
    let gt field value = { node = Compare (field, Int_gt value) }
    let ge field value = { node = Compare (field, Int_ge value) }
    let is_in field values = { node = Compare (field, Int_in values) }
  end

  module Text = struct
    let equal field value = { node = Compare (field, Text_equal value) }

    let starts_with field value =
      { node = Compare (field, Text_starts_with value) }

    let ends_with field value = { node = Compare (field, Text_ends_with value) }
    let contains field value = { node = Compare (field, Text_contains value) }
    let is_in field values = { node = Compare (field, Text_in values) }
  end

  module Rel = struct
    let any relation expression = { node = Related_any (relation, expression) }
    let all relation expression = { node = Related_all (relation, expression) }

    let none relation expression =
      { node = Related_none (relation, expression) }

    let is relation expression = { node = Related_one (relation, expression) }

    let exists relation expression =
      { node = Related_optional (relation, expression) }

    let is_absent relation = { node = Absent relation }
  end

  let compile_comparison : type a. a comparison -> a -> bool = function
    | Bool_equal wanted -> fun value -> Stdlib.Bool.equal value wanted
    | Int_equal wanted -> fun value -> value = wanted
    | Int_lt bound -> fun value -> value < bound
    | Int_le bound -> fun value -> value <= bound
    | Int_gt bound -> fun value -> value > bound
    | Int_ge bound -> fun value -> value >= bound
    | Int_in values -> fun value -> List.exists (Stdlib.Int.equal value) values
    | Text_equal wanted -> String.equal wanted
    | Text_starts_with prefix -> String.starts_with ~prefix
    | Text_ends_with suffix -> String.ends_with ~suffix
    | Text_contains sub ->
        let search = String.find_first ~sub in
        fun value -> Option.is_some (search value)
    | Text_in values -> fun value -> List.exists (String.equal value) values

  let rec compile : type a. a t -> a -> bool =
   fun expression ->
    match expression.node with
    | Compare (field, comparison) ->
        let compare = compile_comparison comparison in
        fun value -> compare (Field.get field value)
    | All children ->
        let predicates = List.map compile children in
        fun value -> List.for_all (fun test -> test value) predicates
    | Any children ->
        let predicates = List.map compile children in
        fun value -> List.exists (fun test -> test value) predicates
    | Not child ->
        let test = compile child in
        fun value -> not (test value)
    | Related_any (relation, child) ->
        let test = compile child in
        fun value -> Iarray.exists test (relation.get value)
    | Related_all (relation, child) ->
        let test = compile child in
        fun value -> Iarray.for_all test (relation.get value)
    | Related_none (relation, child) ->
        let test = compile child in
        fun value -> not (Iarray.exists test (relation.get value))
    | Related_one (relation, child) ->
        let test = compile child in
        fun value -> test (relation.get value)
    | Related_optional (relation, child) ->
        let test = compile child in
        fun value -> Option.fold ~none:false ~some:test (relation.get value)
    | Absent relation -> fun value -> Option.is_none (relation.get value)

  let pp_values pp formatter values =
    Format.fprintf formatter "[%a]"
      (Format.pp_print_list
         ~pp_sep:(fun f () -> Format.pp_print_string f "; ")
         pp)
      values

  let pp_comparison : type a. Format.formatter -> a comparison -> unit =
   fun formatter -> function
    | Bool_equal value -> Format.fprintf formatter "= %b" value
    | Int_equal value -> Format.fprintf formatter "= %d" value
    | Int_lt value -> Format.fprintf formatter "< %d" value
    | Int_le value -> Format.fprintf formatter "<= %d" value
    | Int_gt value -> Format.fprintf formatter "> %d" value
    | Int_ge value -> Format.fprintf formatter ">= %d" value
    | Int_in values ->
        Format.fprintf formatter "in %a" (pp_values Format.pp_print_int) values
    | Text_equal value -> Format.fprintf formatter "= %S" value
    | Text_starts_with value -> Format.fprintf formatter "starts with %S" value
    | Text_ends_with value -> Format.fprintf formatter "ends with %S" value
    | Text_contains value -> Format.fprintf formatter "contains %S" value
    | Text_in values ->
        Format.fprintf formatter "in %a"
          (pp_values (fun f s -> Format.fprintf f "%S" s))
          values

  let rec pp : type a. Format.formatter -> a t -> unit =
   fun formatter expression ->
    match expression.node with
    | Compare (field, comparison) ->
        Format.fprintf formatter "%s %a" (Field.name field) pp_comparison
          comparison
    | All children -> Format.fprintf formatter "all %a" (pp_values pp) children
    | Any children -> Format.fprintf formatter "any %a" (pp_values pp) children
    | Not child -> Format.fprintf formatter "not (%a)" pp child
    | Related_any (relation, child) ->
        Format.fprintf formatter "any %s (%a)" relation.name pp child
    | Related_all (relation, child) ->
        Format.fprintf formatter "all %s (%a)" relation.name pp child
    | Related_none (relation, child) ->
        Format.fprintf formatter "no %s (%a)" relation.name pp child
    | Related_one (relation, child) ->
        Format.fprintf formatter "%s (%a)" relation.name pp child
    | Related_optional (relation, child) ->
        Format.fprintf formatter "present %s (%a)" relation.name pp child
    | Absent relation -> Format.fprintf formatter "absent %s" relation.name

  let describe expression = Format.asprintf "%a" pp expression
end
