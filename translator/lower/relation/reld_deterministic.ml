open Il.Ast
open Maude_ir
open Util.Source

open Reld_result
open Reld_rule_lowering

let rec premise_has_execution_dependency ctx prem =
  match prem.it with
  | RulePr (rel_id, _, _, _) ->
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | Some relation ->
      (match (Relation_shape.of_relation relation).Relation_shape.decision with
      | Relation_shape.Execution _ ->
        not (Analysis.Function_graph.relation_has_maude_equational_view relation)
      | Relation_shape.Static_validation _
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Unknown _ -> false)
    | None -> false)
  | IterPr (prem, _) | NegPr prem -> premise_has_execution_dependency ctx prem
  | IfPr _ | LetPr _ | ElsePr -> false

let rewrite_dependency_diagnostics ctx rel_origin rules =
  rules
  |> List.mapi (fun index rule ->
    let origin = rule_origin rel_origin (index + 1) rule in
    match rule.it with
    | RuleD (_, _, _, _, prems)
      when List.exists (premise_has_execution_dependency ctx) prems ->
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"RelD/deterministic/rewrite-premise"
          ~source_echo:(Il.Print.string_of_rule rule)
          ~reason:
            "deterministic relation lowering cannot emit an equation for a rule whose premise depends on an execution rewrite relation"
          ~suggestion:
            "Use a rewrite-dependent helper/crl lowering for this source rule; do not put rewrite conditions inside ceq/cmb"
          ()
      ]
    | _ -> [])
  |> List.concat

let translate_rule
    ctx
    rel_origin
    op_name
    id
    relation_kind
    relation_mixop
    (shape : Relation_shape.deterministic_shape)
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let names = local_names_for_rule rule in
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin id.it rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      { empty with diagnostics = hint_diags @ marker_diags }
    else
    let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
    let output_typ = shape.Relation_shape.output.typ in
    let expected_typs = input_typs @ [ output_typ ] in
    let components_opt, arity_diags =
      exp_components_match ctx origin "RelD/deterministic/RuleD/arity" expected_typs exp
    in
    let env, var_decls, bind_diags, names =
      translate_rule_binds ctx origin names binds
    in
    (match components_opt with
    | None ->
      { statements = var_decls
      ; diagnostics = hint_diags @ bind_diags @ arity_diags
      }
    | Some components ->
      let input_exps, output_exp =
        match List.rev components with
        | output :: reversed_inputs -> List.rev reversed_inputs, output
        | [] -> [], exp
      in
      let (lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags), names =
        lower_pattern_components_named names ctx env origin input_exps
      in
      (match lhs_terms_opt with
      | None ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
        }
      | Some lhs_terms ->
        let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
        let premise_translation, _names =
          Premise_translate.translate_premises_named
            names
            ctx
            env
            ~bound_conditions:lhs_guards
            ~escape_source_ids:(Source_free_vars.exp_and_note_ids output_exp)
            ~bound_terms:lhs_terms
            origin
            prems
        in
        (match premise_translation with
        | Premise_result.Blocked diagnostics
        | Deferred (_, diagnostics) ->
          { statements = var_decls
          ; diagnostics =
              hint_diags @ bind_diags @ arity_diags @ lhs_diags @ diagnostics
          }
        | Complete premise_result ->
        let rhs_result =
          Expr_translate.lower_value
            ctx (Premise_result.env_after premise_result) origin output_exp
        in
        let diagnostics =
          hint_diags
          @ bind_diags @ arity_diags @ lhs_diags
          @ Premise_result.diagnostics premise_result
          @ rhs_result.diagnostics
        in
        if has_fatal diagnostics then
          { statements = var_decls; diagnostics }
        else
          match rhs_result.term with
          | None -> { statements = var_decls; diagnostics }
          | Some rhs_term ->
            let lhs = relation_call op_name lhs_terms in
            let attrs = if Premise_result.has_else premise_result then [ Owise ] else [] in
            let pattern_certificate =
              Premise_result.condition_pattern_certificate
                ~declarations:var_decls ctx premise_result
            in
            let conditions =
              lhs_guards @ Premise_result.eq_conditions premise_result
              @ rhs_result.guards
              |> Condition_closure.normalize_binding_conditions
                   ~constructor_op:pattern_certificate
                   lhs_terms
              |> dedup_conditions
            in
            let admissibility_diags =
              Condition_admissibility.ceq_admissibility_diagnostics
                ~constructor_op:pattern_certificate
                ctx
                origin
                lhs
                rhs_term
                conditions
            in
            if has_fatal admissibility_diags then
              { statements = var_decls; diagnostics = diagnostics @ admissibility_diags }
            else
              { statements =
                  var_decls
                  @ [ gen origin (ceq lhs rhs_term conditions ~attrs) ]
              ; diagnostics
              })) )

let translate
    ctx origin id relation_kind relation_mixop (shape : Relation_shape.deterministic_shape) rules =
  let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
  let output_typ = shape.Relation_shape.output.typ in
  let rewrite_dependency_diags =
    rewrite_dependency_diagnostics ctx origin rules
  in
  if has_fatal rewrite_dependency_diags then
    { empty with diagnostics = rewrite_dependency_diags }
  else
  let input_sorts_opt, input_diags =
    component_sorts ctx origin "RelD/deterministic/input" input_typs
  in
  let output_sort_opt, output_diags =
    component_sort ctx origin "RelD/deterministic/output" output_typ
  in
  let diagnostics = input_diags @ output_diags in
  if has_fatal diagnostics then
    { empty with diagnostics }
  else
    match input_sorts_opt, output_sort_opt with
    | Some input_sorts, Some output_sort ->
      let op_name = Naming.relation_op id in
      let op_decl =
        gen origin
          (op
             op_name
             (List.map sort_ref input_sorts)
             output_sort)
      in
      let rules_output =
        rules
        |> List.mapi (fun index rule ->
          translate_rule
            ctx
            origin
            op_name
            id
            relation_kind
            relation_mixop
            shape
            (index + 1)
            rule)
        |> List.fold_left append empty
      in
      { statements = op_decl :: rules_output.statements
      ; diagnostics = diagnostics @ rules_output.diagnostics
      }
    | _ -> { empty with diagnostics }
