open Il.Ast
open Maude_ir
open Util.Source

open Reld_common

let append_execution_premise_result left right =
  { Premise_translate.eq_conditions =
      []
  ; rule_conditions =
      left.Premise_translate.rule_conditions
      @ List.map
          (fun condition -> EqCondition condition)
          right.Premise_translate.eq_conditions
      @ right.Premise_translate.rule_conditions
  ; has_else = left.Premise_translate.has_else || right.Premise_translate.has_else
  ; let_bound_ids =
      left.Premise_translate.let_bound_ids @ right.Premise_translate.let_bound_ids
  ; env_after = right.Premise_translate.env_after
  ; bound_vars_after = right.Premise_translate.bound_vars_after
  ; blocked_witness_source_ids =
      List.sort_uniq
        String.compare
        (left.Premise_translate.blocked_witness_source_ids
         @ right.Premise_translate.blocked_witness_source_ids)
  ; runtime_search_requests =
      left.Premise_translate.runtime_search_requests
      @ right.Premise_translate.runtime_search_requests
  ; runtime_truth_search_requests =
      left.Premise_translate.runtime_truth_search_requests
      @ right.Premise_translate.runtime_truth_search_requests
  ; diagnostics = left.Premise_translate.diagnostics @ right.Premise_translate.diagnostics
  }

let unsupported_rule_prem ctx env ~bound_vars origin prem constructor reason =
  let result =
    Premise_translate.translate_premise ctx env ~bound_vars origin prem
  in
  { result with
    Premise_translate.diagnostics =
      result.Premise_translate.diagnostics
      @ [ unsupported
            ~ctx
            ~origin
            ~constructor
            ~source_echo:(Il.Print.string_of_prem prem)
            ~reason
            ~suggestion:
              "Keep this RulePr Unsupported until the enclosing relation lowering can preserve its source operational meaning"
            ()
        ]
  }

let lower_execution_rule_premise ctx env ~bound_vars origin prem rel_id exp =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
  | None ->
    unsupported_rule_prem
      ctx
      env
      ~bound_vars
      origin
      prem
      "Premise/RulePr/unresolved"
      ("relation premise references `" ^ rel_id.it ^ "`, but no matching RelD was found in the source index")
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    (match relation_shape.Relation_shape.decision with
    | Relation_shape.Execution { inputs; outputs; _ } ->
      let input_typs = Relation_shape.component_typs inputs in
      let output_typs = Relation_shape.component_typs outputs in
      (match exp_components_match ctx origin "Premise/RulePr/execution/arity" (input_typs @ output_typs) exp with
      | None, arity_diags ->
        { (Premise_translate.empty) with
          env_after = env
        ; bound_vars_after = bound_vars
        ; diagnostics = arity_diags
        }
      | Some components, arity_diags ->
        let input_count = List.length input_typs in
        let input_exps, output_exps =
          let rec split n left right =
            if n = 0 then List.rev left, right
            else
              match right with
              | [] -> List.rev left, []
              | item :: rest -> split (n - 1) (item :: left) rest
          in
          split input_count [] components
        in
        let input_terms_opt, input_guards, input_diags =
          lower_value_components ctx env origin "rewrite-input" input_exps
        in
        let output_sorts_opt, output_sort_diags =
          component_sorts
            ctx
            origin
            "Premise/RulePr/execution/output"
            output_typs
        in
        let output_pattern_opt, output_guards, introduced, output_diags =
          lower_pattern_components ctx env origin output_exps
        in
        (match input_terms_opt, output_pattern_opt, output_sorts_opt with
        | Some input_terms, Some output_patterns, Some output_sorts
          when List.length output_patterns = List.length output_sorts ->
          let output_pattern = tuple_carrier output_sorts output_patterns in
          let lhs = relation_call (Naming.relation_op rel_id) input_terms in
          let rewrite_condition = RewriteCond (lhs, output_pattern) in
          let rule_conditions =
            rewrite_condition
            :: List.map (fun condition -> EqCondition condition) output_guards
          in
          let env_after = add_introduced_bindings env introduced in
          let bound_vars_after =
            Condition_closure.conditions_bound_vars bound_vars input_guards
            |> fun bound ->
            Condition_closure.rule_conditions_bound_vars bound rule_conditions
            |> List.sort_uniq String.compare
          in
          { (Premise_translate.empty) with
            eq_conditions = input_guards
          ; rule_conditions
          ; env_after
          ; bound_vars_after
          ; diagnostics =
              arity_diags @ input_diags @ output_sort_diags @ output_diags
          }
        | _ ->
          { (Premise_translate.empty) with
            env_after = env
          ; bound_vars_after = bound_vars
          ; diagnostics =
              arity_diags @ input_diags @ output_sort_diags @ output_diags
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/RulePr/execution/output"
                    ~source_echo:(Il.Print.string_of_prem prem)
                    ~reason:
                      "execution RulePr lowering currently supports exactly one output component, so multi-output execution premises remain Unsupported"
                    ()
                ]
          }))
    | _ ->
      unsupported_rule_prem
        ctx
        env
        ~bound_vars
        origin
        prem
        "Premise/RulePr/execution"
        "relation premise is not structurally classified as an execution relation with a split input/output signature")

let prem_origin parent prem =
  Origin.with_child
    ~source_echo:(Il.Print.string_of_prem prem)
    parent
    "premise"
    ~ast_constructor:"Premise"
    prem.at

let translate_execution_premise
    ctx
    env
    ~bound_vars
    ~blocked_witness_source_ids
    ~future_prems
    ~escape_source_ids
    origin
  prem =
  let origin = prem_origin origin prem in
  match prem.it with
  | RulePr (rel_id, args, mixop, exp) ->
    if args <> [] then
      { Premise_translate.empty with
        env_after = env
      ; bound_vars_after = bound_vars
      ; diagnostics =
          [ unsupported
              ~ctx
              ~origin
              ~constructor:"RelD/RulePr/args"
              ~source_echo:(Il.Print.string_of_prem prem)
              ~reason:
                ("execution premise `"
                 ^ rel_id.it
                 ^ "` carries explicit RulePr arguments `"
                 ^ Il.Print.string_of_args args
                 ^ "`, but relation-argument instantiation is not lowered yet")
              ~suggestion:
                "Preserve the RulePr args in analysis and add source-shaped argument instantiation before emitting Maude for this execution premise"
              ()
          ]
      }
    else
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | Some relation ->
      let marker_diags =
        validate_rule_premise_marker
          ctx
          origin
          ~expected_kind:relation.Analysis.Function_graph.kind
          ~expected_mixop:relation.Analysis.Function_graph.mixop
          prem
          mixop
      in
      if has_fatal marker_diags then
        { Premise_translate.empty with
          env_after = env
        ; bound_vars_after = bound_vars
        ; diagnostics = marker_diags
        }
      else
      let relation_shape = Relation_shape.of_relation relation in
      (match relation_shape.Relation_shape.decision with
      | Relation_shape.Execution _ ->
        lower_execution_rule_premise ctx env ~bound_vars origin prem rel_id exp
      | Relation_shape.Deterministic_candidate _ ->
        Premise_translate.translate_premise
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem
      | Relation_shape.Static_validation _ ->
        Premise_translate.translate_premise
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem
      | Relation_shape.Runtime_predicate _ | Relation_shape.Unknown _ ->
        Premise_translate.translate_premise
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem)
    | None ->
      Premise_translate.translate_premise
        ~allow_runtime_search:true
        ~future_prems
        ~escape_source_ids
        ~blocked_witness_source_ids
        ctx
        env
        ~bound_vars
        origin
        prem)
  | IfPr _ | LetPr _ ->
    Premise_translate.translate_premise
      ~allow_runtime_search:true
      ~future_prems
      ~escape_source_ids
      ~blocked_witness_source_ids
      ctx
      env
      ~bound_vars
      origin
      prem
  | ElsePr ->
    let result =
      Premise_translate.translate_premise
        ~allow_runtime_search:true
        ~future_prems
        ~escape_source_ids
        ~blocked_witness_source_ids
        ctx
        env
        ~bound_vars
        origin
        prem
    in
    { result with
      diagnostics =
        result.diagnostics
        @ [ unsupported
              ~ctx
              ~origin
              ~constructor:"RelD/RuleD/ElsePr"
              ~source_echo:(Il.Print.string_of_prem prem)
              ~reason:
                "execution relation otherwise requires a source-derived enabledness complement helper; Maude rule [owise] is not legal here"
              ~suggestion:
                "Implement enabledness complement before lowering execution ElsePr"
              ()
          ]
    }
  | IterPr _ | NegPr _ ->
    Premise_translate.translate_premise
      ~allow_runtime_search:true
      ~future_prems
      ~escape_source_ids
      ~blocked_witness_source_ids
      ctx
      env
      ~bound_vars
      origin
      prem

let translate_premises
    ctx env ?(bound_conditions = []) ?(escape_source_ids = []) ~bound_terms origin prems =
  let bound_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> List.sort_uniq String.compare
    |> fun vars -> Condition_closure.conditions_bound_vars vars bound_conditions
  in
  let rec loop acc = function
    | [] -> acc
    | prem :: future_prems ->
      let result =
        translate_execution_premise
          ctx
          acc.Premise_translate.env_after
          ~bound_vars:acc.Premise_translate.bound_vars_after
          ~blocked_witness_source_ids:acc.Premise_translate.blocked_witness_source_ids
          ~future_prems
          ~escape_source_ids
          origin
          prem
      in
      loop (append_execution_premise_result acc result) future_prems
  in
  let result =
    loop
      { Premise_translate.empty with
        env_after = env
      ; bound_vars_after = bound_vars
      }
      prems
  in
  { result with
    env_after =
      Expr_translate.with_condition_bound_vars
        result.Premise_translate.env_after
        result.Premise_translate.bound_vars_after
  }
