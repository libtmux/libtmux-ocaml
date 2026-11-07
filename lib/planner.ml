type pushdown = Auto | Never | Require_exact

type t = {
  source_filter : string option;
  residual : Graph.Pane.t Filter.Expr.t;
  required_fields : string list;
  required_relations : string list;
  explanation : string;
}

let source_filter plan = plan.source_filter
let residual plan = plan.residual
let required_fields plan = plan.required_fields
let required_relations plan = plan.required_relations
let explanation plan = plan.explanation

let rec exact : type a. a Filter.Expr.t -> string option =
 fun expression ->
  let open Filter in
  let combine op empty expressions =
    let rec collect = function
      | [] -> Some empty
      | [ expression ] -> exact expression
      | expression :: rest ->
          Option.bind (exact expression) (fun first ->
              Option.map
                (fun tail -> "#{" ^ op ^ ":" ^ first ^ "," ^ tail ^ "}")
                (collect rest))
    in
    collect expressions
  in
  match Expr.view expression with
  | Compare (field, Bool_equal expected)
    when List.mem (Field.name field) [ "pane_active"; "pane_dead" ] ->
      Some
        ("#{==:#{" ^ Field.name field ^ "},"
        ^ (if expected then "1" else "0")
        ^ "}")
  | All children -> combine "&&" "1" children
  | Any children -> combine "||" "0" children
  | Not child ->
      Option.map (fun format -> "#{==:" ^ format ^ ",0}") (exact child)
  | _ -> None

let requirements expression =
  let fields = ref [] and relations = ref [] in
  let rec visit : type a. a Filter.Expr.t -> unit =
   fun expression ->
    match Filter.Expr.view expression with
    | Compare (field, _) -> fields := Filter.Field.name field :: !fields
    | All children | Any children -> List.iter visit children
    | Not child -> visit child
    | Related_any (relation, child) ->
        relations := Filter.Relation.Many.name relation :: !relations;
        visit child
    | Related_all (relation, child) ->
        relations := Filter.Relation.Many.name relation :: !relations;
        visit child
    | Related_none (relation, child) ->
        relations := Filter.Relation.Many.name relation :: !relations;
        visit child
    | Related_one (relation, child) ->
        relations := Filter.Relation.One.name relation :: !relations;
        visit child
    | Related_optional (relation, child) ->
        relations := Filter.Relation.Optional.name relation :: !relations;
        visit child
    | Absent relation ->
        relations := Filter.Relation.Optional.name relation :: !relations
  in
  visit expression;
  ( List.sort_uniq String.compare !fields,
    List.sort_uniq String.compare !relations )

let panes ?(pushdown = Auto) expression =
  let source_filter = if pushdown = Never then None else exact expression in
  if pushdown = Require_exact && Option.is_none source_filter then
    Error
      (Error.Unsupported
         "exact pushdown supports only pane flags and Boolean composition")
  else
    let required_fields, required_relations = requirements expression in
    Ok
      {
        source_filter;
        residual = expression;
        required_fields;
        required_relations;
        explanation =
          (match source_filter with
          | Some _ -> "exact pane-flag source filter; retain local evaluation"
          | None -> "capture complete observations and evaluate locally");
      }

let pp formatter plan =
  Format.fprintf formatter "%s; source=%s; residual=%a" plan.explanation
    (Option.value ~default:"none" plan.source_filter)
    Filter.Expr.pp plan.residual
