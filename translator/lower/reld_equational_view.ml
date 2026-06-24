open Maude_ir
open Util.Source

let relation_has_maude_equational_view ctx id =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) id.it with
  | Some relation ->
    Analysis.Function_graph.relation_has_maude_equational_view relation
  | None -> false

let diagnostic ?suggestion ~category ~ctx ~origin ~constructor ~reason () =
  Diagnostics.make
    ?suggestion
    ~category
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let skipped ?suggestion ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ~category:Diagnostics.Skipped
    ~ctx
    ~origin
    ~constructor
    ~reason
    ()

let unsupported_type ctx origin constructor typ =
  diagnostic
    ~category:Diagnostics.Unsupported
    ~ctx
    ~origin
    ~constructor
    ~reason:
      ("unsupported RelD carrier type `" ^ Il.Print.string_of_typ typ ^ "`")
    ~suggestion:
      "Add a source-preserving carrier/witness encoding for this relation component before lowering the RelD"
    ()

let component_sort ctx origin constructor typ =
  match Expr_translate.carrier_sort_of_typ typ with
  | Some sort -> Some sort, []
  | None -> None, [ unsupported_type ctx origin constructor typ ]

let component_sorts ctx origin constructor typs =
  let results = List.map (component_sort ctx origin constructor) typs in
  let sorts = List.filter_map fst results in
  let diagnostics = List.concat (List.map snd results) in
  if List.length sorts = List.length typs then
    Some sorts, diagnostics
  else
    None, diagnostics

let gen origin node =
  Maude_ir.generated ~origin node

let has_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let translate ctx origin id (shape : Relation_shape.execution_shape) rules =
  let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
  let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
  let input_sorts_opt, input_diags =
    component_sorts ctx origin "RelD/equational-view/input" input_typs
  in
  let output_sorts_opt, output_diags =
    component_sorts ctx origin "RelD/equational-view/output" output_typs
  in
  let diagnostics = input_diags @ output_diags in
  if has_fatal diagnostics then
    { Reld_common.empty with diagnostics }
  else
    match input_sorts_opt, output_sorts_opt with
    | Some input_sorts, Some output_sorts ->
      let result_sort =
        match output_sorts with
        | [ sort ] -> sort
        | _ -> sort "SpectecTerminal"
      in
      let op_name = Naming.relation_equational_view_op id in
      let op_decl =
        gen origin
          (op op_name (List.map sort_ref input_sorts) result_sort)
      in
      let rule_diag =
        skipped
          ~ctx
          ~origin
          ~constructor:"RelD/equational-view/rules"
          ~reason:
            (Printf.sprintf
               "relation `%s` is annotated with hint(maude_equational_view); this slice emits the equation-view operator and lets DecD premises call it, while the %d source execution rule(s) remain recorded in provenance rather than rewritten into ceq conditions"
               id.it
               (List.length rules))
          ~suggestion:
            "Add source-derived equations for the annotated view or a verified backend contract before relying on this relation for execution tests"
          ()
      in
      { statements = [ op_decl ]; diagnostics = diagnostics @ [ rule_diag ] }
    | _ -> { Reld_common.empty with diagnostics }
