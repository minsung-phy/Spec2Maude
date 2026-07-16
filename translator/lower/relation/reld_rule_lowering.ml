open Il.Ast
open Maude_ir
open Util.Source
open Reld_result

let gen origin node =
  Maude_ir.generated ~origin node

let app name args =
  App (name, args)

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let rule_origin parent index rule =
  child_origin
    parent
    (Printf.sprintf "RuleD[%d]" index)
    "RuleD"
    rule.at
    (Some (Il.Print.string_of_rule rule))

let rule_label relation_id rule_id index =
  let material =
    if rule_id.it = "" || rule_id.it = "_" then
      relation_id.it ^ "-rule-" ^ string_of_int index
    else
      relation_id.it ^ "-" ^ rule_id.it
  in
  Maude_ir.sanitize_label material

let relation_marker_diagnostics
    ctx
    origin
    ~constructor
    ~source_echo
    ~expected
    ~actual
  =
  if expected = actual then
    []
  else
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo
        ~reason:
          (Printf.sprintf
             "source relation marker mismatch: enclosing/referenced relation is `%s`, but this local mixop is `%s`"
             (Analysis.Relation_graph.string_of_relation_kind expected)
             (Analysis.Relation_graph.string_of_relation_kind actual))
        ~suggestion:
          "Do not erase the local RuleD/RulePr mixop; either prove it matches the referenced relation structurally or keep this case Unsupported"
        ()
    ]

let relation_mixop_skeleton_diagnostics
    ctx
    origin
    ~constructor
    ~source_echo
    ~expected
    ~actual
  =
  if Analysis.Relation_graph.eq_mixop expected actual then
    []
  else
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo
        ~reason:
          (Printf.sprintf
             "source relation mixop skeleton mismatch: enclosing/referenced relation uses `%s`, but this local mixop is `%s`"
             (Analysis.Relation_graph.mixop_shape_text expected)
             (Analysis.Relation_graph.mixop_shape_text actual))
        ~suggestion:
          "Do not collapse distinct source relation skeletons just because their marker class or arity matches"
        ()
    ]

let validate_rule_marker ctx origin ~expected_kind ~expected_mixop rule =
  match rule.it with
  | RuleD (_, _, mixop, _, _) ->
    relation_marker_diagnostics
      ctx
      origin
      ~constructor:"RelD/RuleD/mixop"
      ~source_echo:(Il.Print.string_of_rule rule)
      ~expected:expected_kind
      ~actual:(Analysis.Relation_graph.classify_mixop mixop)
    @ relation_mixop_skeleton_diagnostics
        ctx
        origin
        ~constructor:"RelD/RuleD/mixop-skeleton"
        ~source_echo:(Il.Print.string_of_rule rule)
        ~expected:expected_mixop
        ~actual:mixop

let validate_rule_premise_marker ctx origin ~expected_kind ~expected_mixop prem mixop =
  relation_marker_diagnostics
    ctx
    origin
    ~constructor:"Premise/RulePr/mixop"
    ~source_echo:(Il.Print.string_of_prem prem)
    ~expected:expected_kind
    ~actual:(Analysis.Relation_graph.classify_mixop mixop)
  @ relation_mixop_skeleton_diagnostics
      ctx
      origin
      ~constructor:"Premise/RulePr/mixop-skeleton"
      ~source_echo:(Il.Print.string_of_prem prem)
      ~expected:expected_mixop
      ~actual:mixop

let unsupported_type ctx origin constructor typ =
  unsupported
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

let sequence_of_terms = function
  | [] -> Const "eps"
  | term :: terms ->
    List.fold_left (fun acc term -> app "_ _" [ acc; term ]) term terms

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let tuple_item sort term =
  if is_sequence_sort sort then app "seq" [ term ] else term

let tuple_carrier sorts terms =
  match sorts, terms with
  | [ _ ], [ term ] -> term
  | _ ->
    let items = List.map2 tuple_item sorts terms in
    app "tuple" [ sequence_of_terms items ]

let execution_output_sort = function
  | [ sort ] -> sort
  | _ -> sort "SpectecTerminal"

let relation_conf_sort id =
  sort (Naming.relation_config_sort id)

let frozen_all count =
  let rec loop index acc =
    if index = 0 then acc else loop (index - 1) (index :: acc)
  in
  match loop count [] with
  | [] -> []
  | positions -> [ Frozen positions ]

let lower_exp_bind ctx origin names env bind =
  match bind.it with
  | ExpP (id, typ) ->
    if id.it = "_" then
      env,
      [],
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"RelD/RuleD/ExpP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "wildcard ExpP bind cannot be referenced safely in generated relation rule scope"
          ~suggestion:
            "Implement anonymous pattern bind handling before lowering this RuleD"
          ()
      ], names
    else
      (match Expr_translate.carrier_sort_of_typ typ with
      | Some sort ->
        let term =
          Local_name.source_qualified
            names id.it (Maude_ir.sort_ref sort)
        in
        let binding = { Expr_env.term; sort; typ } in
        let env = Expr_env.add env id.it binding in
        env, [], [], names
      | None ->
        env, [], [ unsupported_type ctx origin "RelD/RuleD/ExpP" typ ], names)
  | TypP id ->
    if Context.find_static_typ ctx id.it <> None then
      env,
      [],
      [ skipped
          ~ctx
          ~origin
          ~constructor:"RelD/RuleD/bind/TypP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time syntax binder is already fixed by the current specialization and has no runtime Maude variable"
          ~suggestion:
            "Keep the binder origin in diagnostics; do not emit it as a runtime argument"
          ()
      ], names
    else
      env,
      [],
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"RelD/RuleD/bind/TypP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time syntax binder is not bound by the current specialization, so erasing it would collapse source structure"
          ~suggestion:
            "Extend finite monomorphization to introduce this local static binder before lowering the RuleD"
          ()
      ], names
  | DefP _ | GramP _ ->
    env,
    [],
    [ unsupported
        ~ctx
        ~origin
        ~constructor:"RelD/RuleD/static-bind"
        ~source_echo:(Il.Print.string_of_quant bind)
        ~reason:
          "definition/grammar static RuleD binds require monomorphization and are outside this relation lowering slice"
        ~suggestion:
          "Specialize the enclosing relation rule before lowering this static binder"
        ()
    ], names

let translate_rule_binds ctx origin names binds =
  binds
  |> List.fold_left
       (fun (env, statements, diagnostics, names) bind ->
         let env, new_statements, new_diagnostics, names =
           lower_exp_bind ctx origin names env bind
         in
         env, statements @ new_statements, diagnostics @ new_diagnostics, names)
       (Expr_env.empty, [], [], names)

let add_introduced_bindings env bindings =
  bindings
  |> List.fold_left
       (fun env (id, binding) -> Expr_env.add env id binding)
       env

let lhs_bound_vars terms guards =
  Condition_closure.conditions_bound_vars
    (terms
     |> List.map Condition_closure.term_vars
     |> List.concat
     |> List.sort_uniq String.compare)
    guards

let add_safe_introduced_bindings env terms guards bindings =
  let bound_vars = lhs_bound_vars terms guards in
  bindings
  |> List.fold_left
       (fun env (id, (binding : Expr_env.binding)) ->
         if
           Condition_closure.vars_subset
                (Condition_closure.term_vars binding.term)
                bound_vars
         then
           Expr_env.add env id binding
         else
           env)
       env

let exp_components_match ctx origin constructor expected_typs exp =
  match Analysis.Relation_graph.exp_components_for_count (List.length expected_typs) exp with
  | Some components -> Some components, []
  | None ->
    None,
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo:(Il.Print.string_of_exp exp)
        ~reason:
          (Printf.sprintf
             "relation rule body does not match the enclosing RelD signature with %d component(s) without flattening source tuple structure"
             (List.length expected_typs))
        ~suggestion:
          "Preserve the source RuleD tuple/mixop shape before lowering this relation rule"
        ()
    ]

let local_names_for_rule_parts quants head prems =
  let free =
    Il.Free.(free_exp head).varid |> Il.Free.Set.elements
    |> List.append
         (prems
          |> List.concat_map (fun prem ->
            Il.Free.(free_prem prem).varid |> Il.Free.Set.elements))
  in
  let bound =
    (Il.Free.(bound_quants quants).varid |> Il.Free.Set.elements)
    @ (prems
       |> List.concat_map (fun prem ->
         Il.Free.(bound_prem prem).varid |> Il.Free.Set.elements))
  in
  Local_name.reserve_sources
    Local_name.empty (List.sort_uniq String.compare (free @ bound))

let local_names_for_rule rule =
  match rule.it with
  | RuleD (_, quants, _, head, prems) ->
    local_names_for_rule_parts quants head prems

let lower_pattern_components_named names ctx env origin exps =
  let source_names =
    exps
    |> List.concat_map (fun exp ->
      Il.Free.(free_exp exp).varid |> Il.Free.Set.elements)
    |> List.sort_uniq String.compare
  in
  let names = Local_name.reserve_sources names source_names in
  let rec lower names results index = function
    | [] -> List.rev results, names
    | exp :: exps ->
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "lhs[%d]" (index + 1))
          "RuleD/LhsExpr"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      let result, names =
        Expr_translate.lower_pattern_with_bindings_named
          names ctx env exp_origin exp
      in
      lower names (result :: results) (index + 1) exps
  in
  let results, names = lower names [] 0 exps in
  let terms =
    List.filter_map
      (fun (result : Expr_result.pattern_result) -> result.pattern_term)
      results
  in
  let guards =
    results
    |> List.map (fun (result : Expr_result.pattern_result) -> result.pattern_guards)
    |> List.concat
  in
  let bindings =
    results
    |> List.map (fun (result : Expr_result.pattern_result) -> result.introduced_bindings)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (result : Expr_result.pattern_result) -> result.pattern_diagnostics)
    |> List.concat
  in
  if List.length terms = List.length exps then
    (Some terms, guards, bindings, diagnostics), names
  else
    (None, guards, bindings, diagnostics), names

let lower_value_components ctx env origin segment exps =
  let results =
    exps
    |> List.mapi (fun index exp ->
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "%s[%d]" segment (index + 1))
          "RuleD/Expr"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      Expr_translate.lower_value ctx env exp_origin exp)
  in
  let terms =
    List.filter_map
      (fun (result : Expr_result.result) -> result.term)
      results
  in
  let guards =
    results
    |> List.map (fun (result : Expr_result.result) -> result.guards)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (result : Expr_result.result) -> result.diagnostics)
    |> List.concat
  in
  if List.length terms = List.length exps then
    Some terms, guards, diagnostics
  else
    None, guards, diagnostics

let relation_call op_name inputs =
  app op_name inputs

let generated_statement_diagnostics
    ?(pattern_certificate = Condition_pattern_certificate.empty)
    ctx statement =
  let ambient_patterns =
    Condition_pattern_certificate.union
      (Condition_closure.source_constructor_certificate ctx)
      pattern_certificate
  in
  let _registry, violations =
    Maude_registry.build
      ~ambient_patterns
      [ statement ]
  in
  Maude_registry.diagnostics
    ~profile:(Context.profile_name ctx)
    violations

let rule_hint_diagnostics ctx origin relation_id rule_id =
  match
    Analysis.Function_graph.rule_hints
      (Context.function_graph ctx)
      ~relation_id
      ~rule_id:rule_id.it
  with
  | None -> []
  | Some rule_hint ->
    rule_hint.hints
    |> List.map (fun hint ->
      let constructor = "RuleD/RuleH/hint(" ^ hint.hintid.it ^ ")" in
      let source_echo =
        Some
          ("RuleH "
           ^ relation_id
           ^ "/"
           ^ rule_id.it
           ^ " hint("
           ^ hint.hintid.it
           ^ ")")
      in
      match Analysis.Hint_policy.classify hint with
      | Analysis.Hint_policy.Presentation ->
        skipped
          ~ctx
          ~origin
          ~constructor
          ?source_echo
          ~reason:
            "rule-local presentation hint is preserved as metadata and does not affect Maude lowering"
          ~suggestion:
            "Keep the RuleH attached to the source rule; no Maude semantic fragment is required for presentation hints"
          ()
      | Analysis.Hint_policy.Semantic_obligation
      | Analysis.Hint_policy.Translator_annotation
      | Analysis.Hint_policy.Unknown ->
        unsupported
          ~ctx
          ~origin
          ~constructor
          ?source_echo
          ~reason:
            ("rule-local hint `"
             ^ hint.hintid.it
             ^ "` is not consumed by this RuleD lowering path")
          ~suggestion:
            "Add a source-shaped RuleH policy before emitting Maude for rules carrying semantic or unknown rule-local hints"
          ())
