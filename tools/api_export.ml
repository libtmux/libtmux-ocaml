(* Development-only reader for the pinned compiler's trusted .cmti artifacts. *)
open Typedtree
open Yojson.Safe.Util

let string value = `String value
let strings values = `List (List.map string values)
let assoc fields = `Assoc fields
let read path = In_channel.with_open_bin path In_channel.input_all
let print printer value = Format.asprintf "@[%a@]" printer value

(* OCaml has separate type and value namespaces. Keep both when spellings match. *)
let distinguish_namespaces symbols =
  let counts = Hashtbl.create 128 in
  List.iter
    (fun symbol ->
      let id = symbol |> member "id" |> to_string in
      Hashtbl.replace counts id
        (1 + Option.value ~default:0 (Hashtbl.find_opt counts id)))
    symbols;
  let renamed =
    symbols
    |> List.filter_map (fun symbol ->
        let id = symbol |> member "id" |> to_string in
        let kind = symbol |> member "kind" |> to_string in
        if
          Hashtbl.find counts id > 1
          && List.mem kind [ "typealias"; "enum"; "struct" ]
        then Some id
        else None)
  in
  let rewrite value =
    match
      List.find_opt
        (fun id -> String.starts_with ~prefix:(id ^ ".") value)
        renamed
    with
    | None -> value
    | Some prefix ->
        prefix ^ ":type"
        ^ String.sub value (String.length prefix)
            (String.length value - String.length prefix)
  in
  List.map
    (fun symbol ->
      let id = symbol |> member "id" |> to_string in
      let kind = symbol |> member "kind" |> to_string in
      let new_id =
        if
          List.mem id renamed && List.mem kind [ "typealias"; "enum"; "struct" ]
        then id ^ ":type"
        else rewrite id
      in
      symbol |> to_assoc
      |> List.map (fun (key, value) ->
          if key = "id" || key = "publicId" then (key, string new_id)
          else if key = "parent" then
            let parent = to_string value in
            ( key,
              string
                (if List.mem parent renamed then parent ^ ":type"
                 else rewrite parent) )
          else (key, value))
      |> assoc)
    symbols

let attributes attrs =
  attrs
  |> List.filter_map (fun (attribute : Parsetree.attribute) ->
      if List.mem attribute.attr_name.txt [ "ocaml.doc"; "ocaml.text" ] then
        match attribute.attr_payload with
        | PStr
            [
              {
                pstr_desc =
                  Pstr_eval
                    ( {
                        pexp_desc =
                          Pexp_constant
                            { pconst_desc = Pconst_string (text, _, _); _ };
                        _;
                      },
                      _ );
                _;
              };
            ] ->
            Some text
        | _ -> failwith "unexpected documentation attribute"
      else None)

type unit_info = {
  name : string;
  package : string;
  product : string;
  submodules : (string * string) list;
  source : string;
  contents : string;
  tree : signature;
  intro : string option;
}

let location unit loc =
  assoc
    [
      ("file", string unit.source);
      ("line", `Int loc.Location.loc_start.pos_lnum);
    ]

let slice unit loc =
  let start = loc.Location.loc_start.pos_cnum
  and finish = loc.loc_end.pos_cnum in
  if start < 0 || finish < start || finish > String.length unit.contents then
    failwith "interface location outside declared source";
  String.sub unit.contents start (finish - start)

let symbols = ref []

let emit unit ~owner ~name ~kind ~loc ~attrs ~raw ?(extra = []) ?documentation
    () =
  let id = if owner = "" then name else owner ^ "." ^ name in
  let product =
    unit.submodules
    |> List.find_map (fun (path, product) ->
        let prefix = unit.name ^ "." ^ path in
        if id = prefix || String.starts_with ~prefix:(prefix ^ ".") id then
          Some product
        else None)
    |> Option.value ~default:unit.product
  in
  let source = location unit loc in
  let docs =
    match documentation with
    | Some docs -> docs
    | None ->
        attributes attrs |> List.filter (fun text -> Some text <> unit.intro)
  in
  let doc =
    if docs = [] then []
    else [ ("doc", Api_doc.decode (String.concat "\n\n" docs)) ]
  in
  symbols :=
    assoc
      ( [
          ("id", string id);
          ("publicId", string id);
          ("qualifiedName", string id);
          ("name", string name);
          ("kind", string kind);
          ("modifiers", `List []);
          ("package", string unit.package);
          ("product", string product);
          ("apiScope", string "exported");
          ("publicOwner", string unit.name);
          ("source", source);
          ("signatures", `List []);
          ("nativeDocumentation", strings docs);
          ( "declarations",
            `List
              [
                assoc
                  [
                    ("kind", string kind);
                    ("text", string (slice unit loc));
                    ("source", source);
                  ];
              ] );
        ]
      |> List.filter (fun (key, _) -> not (List.mem_assoc key extra))
      |> fun fields ->
        fields
        @ (if owner = "" then [] else [ ("parent", string owner) ])
        @ doc
        @ (if raw = "" then [] else [ ("type", string raw) ])
        @ extra )
    :: !symbols;
  id

(* Names resolve only through typed declarations reachable from the public roots. *)
let declarations = Hashtbl.create 128

let rec register root owner tree =
  List.iter
    (fun item ->
      match item.sig_desc with
      | Tsig_module declaration -> register_module root owner declaration
      | Tsig_recmodule declarations ->
          List.iter (register_module root owner) declarations
      | Tsig_modtype declaration ->
          let id = owner ^ "." ^ declaration.mtd_name.txt in
          Hashtbl.replace declarations
            (root, Ident.unique_name declaration.mtd_id)
            id;
          Option.iter (register_type root id) declaration.mtd_type
      | _ -> ())
    tree.sig_items

and register_module root owner declaration =
  match (declaration.md_name.txt, declaration.md_id) with
  | Some name, Some ident ->
      let id = owner ^ "." ^ name in
      Hashtbl.replace declarations (root, Ident.unique_name ident) id;
      register_type root id declaration.md_type
  | _ -> failwith "anonymous public module"

and register_type root owner mty =
  match mty.mty_desc with
  | Tmty_signature tree -> register root owner tree
  | Tmty_with (base, _) -> register_type root owner base
  | _ -> ()

let rec public_path root = function
  | Path.Pident ident when Ident.persistent ident -> Ident.name ident
  | Path.Pident ident -> (
      match Hashtbl.find_opt declarations (root, Ident.unique_name ident) with
      | Some name -> name
      | None -> failwith "alias outside the public module manifest")
  | Path.Pdot (base, name) -> public_path root base ^ "." ^ name
  | Path.Papply _ | Path.Pextra_ty _ -> failwith "unsupported public alias path"

let roots = ref []

let checked_path unit path =
  let target = public_path unit.name path in
  if
    not
      (List.exists
         (fun root ->
           target = root || String.starts_with ~prefix:(root ^ ".") target)
         !roots)
  then failwith ("alias outside the public module manifest: " ^ target);
  target

let parameters typ =
  let rec loop index typ =
    match typ.ctyp_desc with
    | Ttyp_poly (_, inner) -> loop index inner
    | Ttyp_arrow (label, argument, rest) ->
        let name, optional, keyword, next =
          match label with
          | Nolabel -> ("arg" ^ string_of_int index, false, false, index + 1)
          | Labelled name -> (name, false, true, index)
          | Optional name -> (name, true, true, index)
        in
        let argument_type =
          match (label, Types.get_desc argument.ctyp_type) with
          | Optional _, Tconstr (path, [ inner ], _)
            when Path.same path Predef.path_option ->
              inner
          | _ -> argument.ctyp_type
        in
        let remaining, returns = loop next rest in
        ( assoc
            ([
               ("name", string name);
               ("type", string (print Printtyp.type_scheme argument_type));
             ]
            @ (if optional then [ ("optional", `Bool true) ] else [])
            @ if keyword then [ ("keywordOnly", `Bool true) ] else [])
          :: remaining,
          returns )
    | _ -> ([], print Printtyp.type_scheme typ.ctyp_type)
  in
  loop 1 typ

let module_types : (string, unit_info * module_type) Hashtbl.t =
  Hashtbl.create 16

let rec walk unit owner tree =
  List.iter
    (fun item ->
      match item.sig_desc with
      | Tsig_value value ->
          Printtyp.wrap_printing_env ~error:false item.sig_env (fun () ->
              let raw =
                print (Printtyp.value_description value.val_id) value.val_val
              in
              let params, returns = parameters value.val_desc in
              ignore
                (emit unit ~owner ~name:value.val_name.txt
                   ~kind:(if params = [] then "constant" else "function")
                   ~loc:value.val_loc ~attrs:value.val_attributes ~raw:""
                   ~extra:
                     [
                       ( "signatures",
                         `List
                           [
                             assoc
                               [
                                 ("raw", string raw);
                                 ("params", `List params);
                                 ("returns", string returns);
                               ];
                           ] );
                     ]
                   ()))
      | Tsig_type (_, types) ->
          List.iter (walk_type unit owner item.sig_env) types
      | Tsig_module declaration -> walk_module unit owner declaration
      | Tsig_recmodule declarations ->
          List.iter (walk_module unit owner) declarations
      | Tsig_modtype declaration ->
          let id =
            emit unit ~owner ~name:declaration.mtd_name.txt ~kind:"interface"
              ~loc:declaration.mtd_loc ~attrs:declaration.mtd_attributes ~raw:""
              ()
          in
          Option.iter (walk_module_type unit id) declaration.mtd_type
      | Tsig_exception exception_ ->
          let constructor = exception_.tyexn_constructor in
          ignore
            (emit unit ~owner ~name:constructor.ext_name.txt ~kind:"exception"
               ~loc:exception_.tyexn_loc ~attrs:exception_.tyexn_attributes
               ~raw:""
               ~extra:
                 [
                   ( "signatures",
                     `List
                       [
                         assoc
                           [
                             ( "raw",
                               string
                                 (print
                                    (Printtyp.extension_constructor
                                       constructor.ext_id)
                                    constructor.ext_type) );
                             ("params", `List []);
                           ];
                       ] );
                 ]
               ())
      | Tsig_open _ | Tsig_attribute _ -> ()
      | _ ->
          failwith
            ("unsupported public signature at " ^ unit.source ^ ":"
            ^ string_of_int item.sig_loc.loc_start.pos_lnum))
    tree.sig_items

and walk_module unit owner declaration =
  let name = Option.get declaration.md_name.txt in
  let extra =
    match declaration.md_type.mty_desc with
    | Tmty_alias (path, _) ->
        [ ("exportedFrom", string (checked_path unit path)) ]
    | _ -> []
  in
  let id =
    emit unit ~owner ~name ~kind:"module" ~loc:declaration.md_loc
      ~attrs:declaration.md_attributes ~raw:"" ~extra ()
  in
  walk_module_type unit id declaration.md_type

and walk_module_type unit owner mty =
  match mty.mty_desc with
  | Tmty_signature tree -> walk unit owner tree
  | Tmty_ident (path, _) -> (
      let target = checked_path unit path in
      (* Retain the public module type's authored docs/locations when projecting it. *)
      match Hashtbl.find_opt module_types target with
      | Some (source_unit, tree) -> walk_module_type source_unit owner tree
      | None -> failwith ("unresolved public module type: " ^ target))
  | Tmty_alias _ -> ()
  | Tmty_with _ | Tmty_functor _ | Tmty_typeof _ ->
      failwith ("unsupported public module type: " ^ owner)

and walk_type unit owner env declaration =
  Printtyp.wrap_printing_env ~error:false env (fun () ->
      let opaque =
        declaration.typ_kind = Ttype_abstract && declaration.typ_manifest = None
      in
      let normalized =
        print
          (Printtyp.type_declaration declaration.typ_id)
          declaration.typ_type
      in
      let kind =
        match declaration.typ_kind with
        | Ttype_variant _ -> "enum"
        | Ttype_record _ -> "struct"
        | _ -> "typealias"
      in
      let extra =
        [
          ( "signatures",
            `List [ assoc [ ("raw", string normalized); ("params", `List []) ] ]
          );
        ]
        @ if opaque then [ ("modifiers", strings [ "opaque" ]) ] else []
      in
      let id =
        emit unit ~owner ~name:declaration.typ_name.txt ~kind
          ~loc:declaration.typ_loc ~attrs:declaration.typ_attributes
          ~raw:
            (match declaration.typ_manifest with
            | None -> ""
            | Some typ -> print Printtyp.type_scheme typ.ctyp_type)
          ~extra ()
      in
      match declaration.typ_kind with
      | Ttype_record labels ->
          List.iter (walk_label ~namespace:owner unit id) labels
      | Ttype_variant constructors ->
          List.iter
            (fun constructor ->
              let variant =
                match constructor.cd_args with
                | Cstr_record _ -> "struct"
                | Cstr_tuple [] -> "unit"
                | Cstr_tuple _ -> "tuple"
              in
              let child =
                emit unit ~owner:id ~name:constructor.cd_name.txt
                  ~kind:"constant" ~loc:constructor.cd_loc
                  ~attrs:constructor.cd_attributes ~raw:""
                  ~extra:
                    [
                      ("variant", string variant);
                      ( "qualifiedName",
                        string (owner ^ "." ^ constructor.cd_name.txt) );
                    ]
                  ()
              in
              match constructor.cd_args with
              | Cstr_record labels ->
                  List.iter (walk_label ~namespace:owner unit child) labels
              | _ -> ())
            constructors
      | _ -> ())

and walk_label ?namespace unit owner label =
  ignore
    (emit unit ~owner ~name:label.ld_name.txt ~kind:"attribute"
       ~loc:label.ld_loc ~attrs:label.ld_attributes
       ~raw:(print Printtyp.type_scheme label.ld_type.ctyp_type)
       ~extra:
         (match namespace with
         | None -> []
         | Some parent ->
             [ ("qualifiedName", string (parent ^ "." ^ label.ld_name.txt)) ])
       ())

let rec collect_types unit owner tree =
  List.iter
    (fun item ->
      match item.sig_desc with
      | Tsig_modtype declaration ->
          Option.iter
            (fun typ ->
              Hashtbl.add module_types
                (owner ^ "." ^ declaration.mtd_name.txt)
                (unit, typ))
            declaration.mtd_type
      | Tsig_module declaration -> collect_module unit owner declaration
      | Tsig_recmodule declarations ->
          List.iter (collect_module unit owner) declarations
      | _ -> ())
    tree.sig_items

and collect_module unit owner declaration =
  match declaration.md_type.mty_desc with
  | Tmty_signature tree ->
      collect_types unit (owner ^ "." ^ Option.get declaration.md_name.txt) tree
  | _ -> ()

let () =
  try
    if Array.length Sys.argv <> 3 then
      failwith "usage: api_export SOURCE_ROOT MANIFEST";
    if Sys.ocaml_version <> "5.5.2" then
      failwith "exporter requires OCaml 5.5.2";
    let root = Sys.argv.(1) in
    let manifest = Yojson.Safe.from_file Sys.argv.(2) in
    let modules = manifest |> member "modules" |> to_list in
    let units =
      List.map
        (fun entry ->
          let name = entry |> member "module" |> to_string in
          let source = entry |> member "source" |> to_string in
          if
            (not (Filename.is_relative source))
            || List.mem ".." (String.split_on_char '/' source)
          then failwith "source must be repository-relative";
          let cmti = entry |> member "cmti" |> to_string in
          if not (Filename.check_suffix cmti ".cmti") then
            failwith "complete .cmti required; .cmi is signature-only";
          let contents = read (Filename.concat root source) in
          let cmi, cmt = Cmt_format.read (Filename.concat root cmti) in
          match (cmi, cmt) with
          | Some cmi, Some cmt
            when cmi.cmi_name = name && cmt.cmt_modname = name -> (
              if cmt.cmt_source_digest <> Some (Digest.BLAKE128.string contents)
              then failwith ("source digest mismatch: " ^ source);
              match cmt.cmt_annots with
              | Interface tree ->
                  if
                    print Printtyp.signature cmi.cmi_sign
                    <> print Printtyp.signature tree.sig_type
                  then failwith "embedded CMI signature mismatch";
                  let intro =
                    cmt.cmt_comments
                    |> List.find_map (fun (text, loc) ->
                        if
                          loc.Location.loc_start.pos_cnum = 0
                          && String.starts_with ~prefix:"*" text
                        then Some (String.sub text 1 (String.length text - 1))
                        else None)
                  in
                  {
                    name;
                    source;
                    contents;
                    tree;
                    intro;
                    package = entry |> member "package" |> to_string;
                    product = entry |> member "product" |> to_string;
                    submodules =
                      (match entry |> member "submodules" with
                        | `Null -> []
                        | value ->
                            value |> to_assoc
                            |> List.map (fun (path, value) ->
                                (path, to_string value)))
                      |> List.sort (fun (a, _) (b, _) ->
                          Int.compare (String.length b) (String.length a));
                  }
              | _ -> failwith "complete interface annotation required")
          | _ ->
              failwith
                "public module does not match embedded CMI and typed interface")
        modules
    in
    roots := List.map (fun unit -> unit.name) units;
    List.iter
      (fun unit ->
        register unit.name unit.name unit.tree;
        collect_types unit unit.name unit.tree)
      units;
    List.iter
      (fun unit ->
        let attrs =
          unit.tree.sig_items
          |> List.filter_map (fun item ->
              match item.sig_desc with
              | Tsig_attribute attr -> Some attr
              | _ -> None)
        in
        let loc =
          Location.
            {
              loc_start = { Lexing.dummy_pos with pos_lnum = 1; pos_cnum = 0 };
              loc_end = { Lexing.dummy_pos with pos_lnum = 1; pos_cnum = 0 };
              loc_ghost = false;
            }
        in
        ignore
          (emit unit ~owner:"" ~name:unit.name ~kind:"module" ~loc ~attrs
             ~raw:""
             ~documentation:(Option.to_list unit.intro)
             ());
        walk unit unit.name unit.tree)
      units;
    let sorted =
      distinguish_namespaces !symbols
      |> List.sort (fun a b ->
          String.compare
            (a |> member "id" |> to_string)
            (b |> member "id" |> to_string))
    in
    Yojson.Safe.to_channel stdout
      (assoc
         [
           ("schema", string "libtmux.ocaml-api/1");
           ("compiler", string Sys.ocaml_version);
           ("symbols", `List sorted);
         ]);
    print_newline ()
  with exception_ ->
    Format.eprintf "API export: %s@." (Printexc.to_string exception_);
    exit 1
