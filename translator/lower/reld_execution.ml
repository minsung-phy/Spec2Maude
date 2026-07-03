open Il.Ast
open Maude_ir
open Util.Source

open Reld_common

let has_else_premise prems =
  prems
  |> List.exists (fun prem ->
    match prem.it with
    | ElsePr -> true
    | _ -> false)

let without_else_premises prems =
  prems
  |> List.filter (fun prem ->
    match prem.it with
    | ElsePr -> false
    | _ -> true)

let translate_rule
    ctx
    rel_origin
    op_name
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    input_sorts
    output_sorts
    previous_rules
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id.it rule_id in
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
    let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
    let expected_typs = input_typs @ output_typs in
    let components_opt, arity_diags =
      exp_components_match ctx origin "RelD/execution/RuleD/arity" expected_typs exp
    in
    let seed = op_name ^ "-rule-" ^ string_of_int index in
    let env, var_decls, bind_diags =
      translate_rule_binds ctx origin seed binds
    in
    (match components_opt with
    | None ->
      { statements = var_decls
      ; diagnostics = hint_diags @ bind_diags @ arity_diags
      }
    | Some components ->
      let input_count = List.length input_typs in
      let rec split n left right =
        if n = 0 then List.rev left, right
        else
          match right with
          | [] -> List.rev left, []
          | item :: rest -> split (n - 1) (item :: left) rest
      in
      let input_exps, output_exps = split input_count [] components in
      let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
        lower_pattern_components ctx env origin input_exps
      in
      (match lhs_terms_opt with
      | Some lhs_terms ->
        let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
        let has_else = has_else_premise prems in
        let else_output, else_conditions =
          if has_else then
            Reld_enabledness.complement
              ctx
              rel_origin
              relation_id
              relation_kind
              relation_mixop
              shape
              input_sorts
              origin
              lhs_terms
              previous_rules
          else
            empty, []
        in
        let premise_result =
          Reld_execution_premise.translate_premises
            ctx
            env
            ~bound_conditions:lhs_guards
            ~escape_source_ids:
              (output_exps
               |> List.concat_map Premise_capture.source_and_note_free_var_ids
               |> List.sort_uniq String.compare)
            ~bound_terms:lhs_terms
            origin
            (without_else_premises prems)
        in
        let output_terms_opt, output_guards, output_diags =
          lower_value_components
            ctx
            premise_result.env_after
            origin
            "rhs"
            output_exps
        in
        let diagnostics =
          hint_diags
          @ bind_diags @ arity_diags @ lhs_diags @ output_diags
          @ else_output.diagnostics @ premise_result.diagnostics
        in
        if has_fatal diagnostics then
          { statements = var_decls; diagnostics }
        else
          (match output_terms_opt with
          | Some output_terms
            when List.length output_terms = List.length output_sorts ->
            let rhs_term = tuple_carrier output_sorts output_terms in
            let lhs = relation_call op_name lhs_terms in
            let conditions =
              List.map (fun condition -> EqCondition condition) lhs_guards
              @ else_conditions
              @ premise_result.rule_conditions
              @ List.map (fun condition -> EqCondition condition) output_guards
              |> Condition_closure.normalize_rule_conditions [ lhs ]
              |> dedup_rule_conditions
            in
            let admissibility_diags =
              Condition_closure.crl_admissibility_diagnostics
                ctx
                origin
                lhs
                rhs_term
                conditions
            in
            if has_fatal admissibility_diags then
              { statements = var_decls
              ; diagnostics = diagnostics @ admissibility_diags
              }
            else
              let statement =
                gen origin
                  (crl
                     ~label:(rule_label relation_id rule_id index)
                     lhs
                     rhs_term
                     conditions)
              in
              let registry_diags =
                generated_statement_diagnostics ctx statement
              in
              if has_fatal registry_diags then
                { statements = []
                ; diagnostics = diagnostics @ registry_diags
                }
              else
                { statements = var_decls @ else_output.statements @ [ statement ]
                ; diagnostics
                }
          | Some _ ->
            { statements = var_decls
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/execution/output"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "execution relation lowering currently supports exactly one output component; multi-output execution rules remain Unsupported"
                      ()
                  ]
            }
          | None -> { statements = var_decls; diagnostics })
      | _ ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
        }))

let translate ctx origin id relation_kind relation_mixop shape rules =
  let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
  let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
  let input_sorts_opt, input_diags =
    component_sorts ctx origin "RelD/execution/input" input_typs
  in
  let output_sorts_opt, output_diags =
    component_sorts ctx origin "RelD/execution/output" output_typs
  in
  let diagnostics = input_diags @ output_diags in
  if has_fatal diagnostics then
    { empty with diagnostics }
  else
    match input_sorts_opt, output_sorts_opt with
    | Some input_sorts, Some output_sorts ->
      let op_name = Naming.relation_op id in
      let conf_sort = relation_conf_sort id in
      let output_sort = execution_output_sort output_sorts in
      let header =
        [ gen origin (sort_decl conf_sort)
        ; gen origin (subsort output_sort conf_sort)
        ; gen origin
            (op
               ~attrs:(frozen_all (List.length input_sorts))
               op_name
               (List.map sort_ref input_sorts)
               conf_sort)
        ]
      in
      let rules_output =
        let rec loop previous index = function
          | [] -> empty
          | rule :: rest ->
            let current =
              translate_rule
                ctx
                origin
                op_name
                id
                relation_kind
                relation_mixop
                shape
                input_sorts
                output_sorts
                previous
                index
                rule
            in
            append current (loop (previous @ [ rule ]) (index + 1) rest)
        in
        loop [] 1 rules
      in
      { statements = header @ dedup_generated rules_output.statements
      ; diagnostics = diagnostics @ rules_output.diagnostics
      }
    | _ -> { empty with diagnostics }
