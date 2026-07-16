open Il.Ast
open Maude_ir
open Util.Source

open Reld_result
open Reld_rule_lowering

let append_execution_premise_result ctx origin names left right =
  let right_conditions, rewrite_diagnostics, names =
    Decd_rewrite_condition.lower_eq_conditions
      ctx origin names (Premise_result.eq_conditions right)
  in
  ( { Premise_result.eq_conditions =
      []
  ; enabledness_condition_blocks =
      left.Premise_result.enabledness_condition_blocks
      @ Premise_result.enabledness_condition_blocks right
  ; head_domain_failures =
      left.Premise_result.head_domain_failures
      @ Premise_result.head_domain_failures right
  ; source_condition_certificates =
      left.Premise_result.source_condition_certificates
      @ Premise_result.source_condition_certificates right
  ; source_condition_failures =
      left.Premise_result.source_condition_failures
      @ Premise_result.source_condition_failures right
  ; rule_conditions =
      left.Premise_result.rule_conditions
      @ right_conditions
      @ Premise_result.rule_conditions right
  ; has_else = left.Premise_result.has_else || Premise_result.has_else right
  ; let_bound_ids =
      left.Premise_result.let_bound_ids @ Premise_result.let_bound_ids right
  ; env_after = Premise_result.env_after right
  ; lhs_bound_vars = left.Premise_result.lhs_bound_vars
  ; bound_vars_after = Premise_result.bound_vars_after right
  ; blocked_witness_source_ids =
      List.sort_uniq
        String.compare
        (left.Premise_result.blocked_witness_source_ids
         @ Premise_result.blocked_witness_source_ids right)
  ; runtime_search_requests =
      left.Premise_result.runtime_search_requests
      @ Premise_result.runtime_search_requests right
  ; runtime_truth_search_requests =
      left.Premise_result.runtime_truth_search_requests
      @ Premise_result.runtime_truth_search_requests right
  ; runtime_truth_worklist_requests =
      left.Premise_result.runtime_truth_worklist_requests
      @ Premise_result.runtime_truth_worklist_requests right
  ; pattern_certificate =
      Condition_pattern_certificate.union
        left.Premise_result.pattern_certificate
        (Premise_result.pattern_certificate right)
  ; diagnostics =
      left.Premise_result.diagnostics @ Premise_result.diagnostics right
      @ rewrite_diagnostics
    }
  , names )

let unsupported_rule_prem
    ctx env ~bound_vars ~lhs_bound_vars origin prem constructor reason =
  let _ = env, bound_vars, lhs_bound_vars in
  Premise_result.blocked
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo:(Il.Print.string_of_prem prem)
        ~reason
        ~suggestion:
          "Keep this RulePr Unsupported until the enclosing relation lowering can preserve its source operational meaning"
        ()
    ]

let lower_execution_rule_premise
    names ctx env ~bound_vars ~lhs_bound_vars origin prem rel_id exp =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
  | None ->
    ( unsupported_rule_prem
      ctx
      env
      ~bound_vars
      ~lhs_bound_vars
      origin
      prem
      "Premise/RulePr/unresolved"
      ("relation premise references `" ^ rel_id.it ^ "`, but no matching RelD was found in the source index")
    , names )
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    (match relation_shape.Relation_shape.decision with
    | Relation_shape.Execution { inputs; outputs; _ } ->
      let input_typs = Relation_shape.component_typs inputs in
      let output_typs = Relation_shape.component_typs outputs in
      (match exp_components_match ctx origin "Premise/RulePr/execution/arity" (input_typs @ output_typs) exp with
      | None, arity_diags ->
        ( Premise_result.classify
          { Premise_result.empty with
            env_after = env
          ; bound_vars_after = bound_vars
          ; diagnostics = arity_diags
            }
        , names )
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
        let (output_pattern_opt, output_guards, introduced, output_diags), names =
          lower_pattern_components_named names ctx env origin output_exps
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
            Condition_closure.conditions_bound_vars
              ~constructor_op:
                (Condition_closure.source_constructor_certificate ctx)
              bound_vars input_guards
            |> fun bound ->
            Condition_closure.rule_conditions_bound_vars
              ~constructor_op:
                (Condition_closure.source_constructor_certificate ctx)
              bound rule_conditions
            |> List.sort_uniq String.compare
          in
          ( Premise_result.classify
            { Premise_result.empty with
              eq_conditions = input_guards
            ; rule_conditions
            ; env_after
            ; bound_vars_after
            ; diagnostics =
                arity_diags @ input_diags @ output_sort_diags @ output_diags
              }
          , names )
        | _ ->
          ( Premise_result.classify
            { Premise_result.empty with
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
              }
          , names )))
    | _ ->
      ( unsupported_rule_prem
        ctx
        env
        ~bound_vars
        ~lhs_bound_vars
        origin
        prem
        "Premise/RulePr/execution"
        "relation premise is not structurally classified as an execution relation with a split input/output signature"
      , names ))

let prem_origin parent prem =
  Origin.with_child
    ~source_echo:(Il.Print.string_of_prem prem)
    parent
    "premise"
    ~ast_constructor:"Premise"
    prem.at

let translate_execution_premise
    names
    ~require_equational_contract
    ctx
    env
    ~bound_vars
    ~lhs_bound_vars
    ~blocked_witness_source_ids
    ~future_prems
    ~escape_source_ids
    origin
  prem =
  let origin = prem_origin origin prem in
  match prem.it with
  | RulePr (rel_id, args, mixop, exp) ->
    if args <> [] then
      ( Premise_result.blocked
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
      , names )
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
        Premise_result.blocked marker_diags, names
      else
      let relation_shape = Relation_shape.of_relation relation in
      (match relation_shape.Relation_shape.decision with
      | Relation_shape.Execution _ ->
        if require_equational_contract
           && not (Analysis.Function_graph.relation_has_maude_equational_view relation)
        then
          ( unsupported_rule_prem
            ctx env ~bound_vars ~lhs_bound_vars origin prem
            "Premise/RulePr/execution/unannotated-rewrite-dependency"
            "rewrite-backed DecD premise calls an execution relation without hint(maude_equational_view); no right-uniqueness contract permits this functional dependency"
          , names )
        else
          lower_execution_rule_premise
            names ctx env ~bound_vars ~lhs_bound_vars origin prem rel_id exp
      | Relation_shape.Deterministic_candidate _ ->
        Premise_translate.translate_premise_named
          names
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ~lhs_bound_vars
          ctx
          env
          ~bound_vars
          origin
          prem
      | Relation_shape.Static_validation _ ->
        Premise_translate.translate_premise_named
          names
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ~lhs_bound_vars
          ctx
          env
          ~bound_vars
          origin
          prem
      | Relation_shape.Runtime_predicate _ | Relation_shape.Unknown _ ->
        Premise_translate.translate_premise_named
          names
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ~lhs_bound_vars
          ctx
          env
          ~bound_vars
          origin
          prem)
    | None ->
      Premise_translate.translate_premise_named
        names
        ~allow_runtime_search:true
        ~future_prems
        ~escape_source_ids
        ~blocked_witness_source_ids
        ~lhs_bound_vars
        ctx
        env
        ~bound_vars
        origin
        prem)
  | IfPr _ | LetPr _ ->
    Premise_translate.translate_premise_named
      names
      ~allow_runtime_search:true
      ~future_prems
      ~escape_source_ids
      ~blocked_witness_source_ids
      ~lhs_bound_vars
      ctx
      env
      ~bound_vars
      origin
      prem
  | ElsePr ->
    let result, names =
      Premise_translate.translate_premise_named
        names
        ~allow_runtime_search:true
        ~future_prems
        ~escape_source_ids
        ~blocked_witness_source_ids
        ~lhs_bound_vars
        ctx
        env
        ~bound_vars
        origin
        prem
    in
    let diagnostic =
      unsupported
        ~ctx
        ~origin
        ~constructor:"RelD/RuleD/ElsePr"
        ~source_echo:(Il.Print.string_of_prem prem)
        ~reason:
          "execution relation otherwise requires a source-derived enabledness complement helper; Maude rule [owise] is not legal here"
        ~suggestion:
          "Implement enabledness complement before lowering execution ElsePr"
        ()
    in
    (match result with
    | Premise_result.Complete result ->
      ( Premise_result.blocked (Premise_result.diagnostics result @ [ diagnostic ])
      , names )
    | Blocked diagnostics | Deferred (_, diagnostics) ->
      Premise_result.blocked (diagnostics @ [ diagnostic ]), names)
  | IterPr _ | NegPr _ ->
    Premise_translate.translate_premise_named
      names
      ~allow_runtime_search:true
      ~future_prems
      ~escape_source_ids
      ~blocked_witness_source_ids
      ~lhs_bound_vars
      ctx
      env
      ~bound_vars
      origin
      prem

let translate_premises_named
    names
    ?(require_equational_contract = false)
    ctx env ?(bound_conditions = []) ?(escape_source_ids = []) ~bound_terms origin prems =
  let incoming_names = names in
  let source_names =
    let free = Il.Free.(free_prems prems).varid |> Il.Free.Set.elements in
    let bound =
      prems
      |> List.concat_map (fun prem ->
        Il.Free.(bound_prem prem).varid |> Il.Free.Set.elements)
    in
    List.sort_uniq String.compare (free @ bound)
  in
  let names = Local_name.reserve_sources names source_names in
  let condition_vars = function
    | EqCond (left, right) | MatchCond (left, right) ->
      Condition_closure.term_vars left @ Condition_closure.term_vars right
    | MembershipCond (term, _) | BoolCond term ->
      Condition_closure.term_vars term
  in
  let existing_vars =
    Expr_env.bound_vars env
    @ List.concat_map Condition_closure.term_vars bound_terms
    @ List.concat_map condition_vars bound_conditions
  in
  let names = Local_name.reserve_existing_many names existing_vars in
  let lhs_term_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> List.sort_uniq String.compare
  in
  let lhs_bound_vars =
    Condition_closure.conditions_bound_vars
      ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
      lhs_term_vars bound_conditions
  in
  let bound_vars = lhs_bound_vars in
  let rec loop acc names = function
    | [] -> Premise_result.classify acc, names
    | prem :: future_prems ->
      let stage = Context.begin_stage ctx in
      let staged = Context.staged stage in
      let result, candidate_names =
        translate_execution_premise
          names
          ~require_equational_contract
          staged
          acc.Premise_result.env_after
          ~bound_vars:acc.Premise_result.bound_vars_after
          ~lhs_bound_vars
          ~blocked_witness_source_ids:acc.Premise_result.blocked_witness_source_ids
          ~future_prems
          ~escape_source_ids
          origin
          prem
      in
      (match result with
      | Premise_result.Complete result ->
        let acc, candidate_names =
          append_execution_premise_result
            staged origin candidate_names acc result
        in
        (match Premise_result.classify acc with
        | Premise_result.Complete _ ->
          Context.commit_stage stage;
          loop acc candidate_names future_prems
        | Blocked diagnostics -> Premise_result.blocked diagnostics, names
        | Deferred (deferral, diagnostics) ->
          Premise_result.deferred deferral diagnostics, names)
      | Blocked diagnostics ->
        Premise_result.blocked (acc.diagnostics @ diagnostics), names
      | Deferred (deferral, diagnostics) ->
        Premise_result.deferred deferral (acc.diagnostics @ diagnostics), names)
  in
  let result, names =
    loop
      { Premise_result.empty with
        env_after = env
      ; lhs_bound_vars
      ; bound_vars_after = bound_vars
      }
      names
      prems
  in
  match result with
  | Premise_result.Complete result ->
    Premise_result.finalize_condition_bound_vars result, names
  | Premise_result.Blocked _ as blocked -> blocked, incoming_names
  | Premise_result.Deferred _ as deferred -> deferred, incoming_names
