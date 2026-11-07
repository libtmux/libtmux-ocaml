open Libtmux
open Model_fixture

let editors =
  Expr.all
    [
      Expr.Bool.is_true Pane.Fields.active;
      Expr.Text.is_in Pane.Fields.current_command [ "nvim"; "vim" ];
      Expr.Int.ge Pane.Fields.width 120;
    ]

let query_contract () =
  let captured = snapshot () in
  let panes = Snapshot.panes captured |> Iarray.to_list in
  let adapter = Query.matching editors in
  let selected = List.to_seq (panes @ panes) |> adapter in
  let ids () =
    selected |> Seq.map (fun p -> Pane.Id.to_string (Pane.id p)) |> List.of_seq
  in
  Alcotest.(check (list string))
    "order and multiplicity" [ "%1"; "%1" ] (ids ());
  Alcotest.(check (list string)) "replay" (ids ()) (ids ());
  let window = Iarray.get (Snapshot.windows captured) 0 in
  let active = Expr.Bool.is_true Pane.Fields.active in
  let shell = Expr.Text.equal Pane.Fields.current_command "sh" in
  let same_child =
    Expr.Rel.any Window.Relations.panes (Expr.all [ active; shell ])
  in
  let different_children =
    Expr.all
      [
        Expr.Rel.any Window.Relations.panes active;
        Expr.Rel.any Window.Relations.panes shell;
      ]
  in
  Alcotest.(check bool)
    "one child must satisfy both" false
    (Expr.compile same_child window);
  Alcotest.(check bool)
    "separate existential witnesses" true
    (Expr.compile different_children window);
  let sessions_with_editors =
    Expr.Rel.any Session.Relations.windows
      (Expr.Rel.any Window.Relations.panes editors)
  in
  Alcotest.(check int)
    "nested relation" 2
    (Snapshot.sessions captured |> Iarray.to_seq
    |> Query.matching sessions_with_editors
    |> Seq.length);
  let clients =
    Snapshot.Input.
      [
        {
          name = "detached";
          session_id = None;
          pid = 1;
          width = 80;
          height = Some 24;
          control_mode = true;
        };
      ]
  in
  let client = Iarray.get (Snapshot.clients (get (make ~clients ()))) 0 in
  Alcotest.(check bool)
    "optional absence" true
    (Expr.compile
       (Expr.Rel.is_absent Client_observation.Relations.session)
       client);
  Alcotest.(check bool)
    "absent relation cannot match" false
    (Expr.compile
       (Expr.Rel.exists Client_observation.Relations.session (Expr.all []))
       client)

let empty_quantifiers () =
  (* Complete tmux graphs have children; exercise the generic evaluator's empty edge. *)
  let module F = Libtmux__Filter in
  let children = F.Relation.Many.{ name = "children"; get = Iarray.of_list } in
  let condition = F.Expr.all [] in
  Alcotest.(check bool)
    "any empty" false
    (F.Expr.compile (F.Expr.Rel.any children condition) []);
  Alcotest.(check bool)
    "all empty" true
    (F.Expr.compile (F.Expr.Rel.all children condition) []);
  Alcotest.(check bool)
    "none empty" true
    (F.Expr.compile (F.Expr.Rel.none children condition) []);
  Alcotest.(check bool) "empty conjunction" true (Expr.compile (Expr.all []) ());
  Alcotest.(check bool)
    "empty disjunction" false
    (Expr.compile (Expr.any []) ())

let scalar_equivalence () =
  let contains value sub =
    let rec search at =
      at + String.length sub <= String.length value
      && (String.sub value at (String.length sub) = sub || search (at + 1))
    in
    search 0
  in
  let generator = QCheck2.Gen.(triple string_small (int_range 1 240) bool) in
  let property (title, width, active) =
    let first = { (List.hd panes) with Snapshot.Input.title; width; active } in
    let second =
      { (List.nth panes 1) with Snapshot.Input.active = not active }
    in
    let pane =
      Iarray.get (Snapshot.panes (get (make ~panes:[ first; second ] ()))) 0
    in
    let expression =
      Expr.all
        [
          Expr.any
            [
              Expr.Int.ge Pane.Fields.width 120;
              Expr.Text.contains Pane.Fields.title "a";
            ];
          Expr.not_ (Expr.Bool.is_false Pane.Fields.active);
          Expr.Text.contains Pane.Fields.title "";
          Expr.Int.is_in Pane.Fields.width [ width; 0 ];
          Expr.Text.starts_with Pane.Fields.title (String.take_first 2 title);
          Expr.Text.ends_with Pane.Fields.title (String.take_last 2 title);
        ]
    in
    Bool.equal
      (Expr.compile expression pane)
      ((width >= 120 || contains title "a") && active)
  in
  QCheck2.Test.check_exn
    ~rand:(Random.State.make [| 2026; 11; 6 |])
    (QCheck2.Test.make
       ~name:"typed scalar evaluation agrees with native predicates" ~count:2000
       generator property)

let () =
  Alcotest.run "typed queries"
    [
      ( "contracts",
        [
          Alcotest.test_case "relations, replay and multiplicity" `Quick
            query_contract;
          Alcotest.test_case "empty quantifiers" `Quick empty_quantifiers;
          Alcotest.test_case "native predicate equivalence" `Quick
            scalar_equivalence;
        ] );
    ]
