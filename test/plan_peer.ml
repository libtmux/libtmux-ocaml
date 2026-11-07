open Libtmux

let () =
  let panes =
    Array.to_list Sys.argv |> List.tl
    |> List.mapi (fun index line ->
        match String.split_on_char ':' line with
        | [ id; active; dead ] ->
            {
              (List.hd Model_fixture.panes) with
              Snapshot.Input.id = Model_fixture.pane_id id;
              index;
              active = active = "1";
              dead = dead = "1";
            }
        | _ -> failwith "invalid fixture flags")
  in
  let snapshot = Model_fixture.get (Model_fixture.make ~panes ()) in
  let active = Expr.Bool.is_true Pane.Fields.active in
  let dead = Expr.Bool.is_true Pane.Fields.dead in
  let cases =
    [
      ("active", active);
      ("inactive", Expr.Bool.is_false Pane.Fields.active);
      ("dead", dead);
      ("not-dead", Expr.not_ dead);
      ("none", Expr.any []);
      ("all", Expr.all []);
      ("or", Expr.any [ active; dead ]);
      ("and", Expr.all [ active; Expr.not_ dead ]);
      ("not-or", Expr.not_ (Expr.any [ active; dead ]));
      ("nested", Expr.any [ Expr.all [ active; dead ]; Expr.not_ active ]);
    ]
  in
  let results =
    List.map
      (fun (name, expression) ->
        let plan =
          Model_fixture.get (Plan.panes ~pushdown:Require_exact expression)
        in
        let matches =
          Snapshot.panes snapshot |> Iarray.to_seq |> Query.matching expression
          |> Seq.map (fun pane -> `String (Pane.Id.to_string (Pane.id pane)))
          |> List.of_seq
        in
        `Assoc
          [
            ("name", `String name);
            ("source", `String (Option.get (Plan.source_filter plan)));
            ("matches", `List matches);
          ])
      cases
  in
  Yojson.Safe.to_channel stdout (`List results);
  print_newline ()
