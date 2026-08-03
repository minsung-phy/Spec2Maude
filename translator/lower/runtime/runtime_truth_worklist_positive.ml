open Maude_ir
open Il.Ast
open Util.Source

open Runtime_truth_worklist_core
open Runtime_truth_worklist_premise

module Request = Helper_request

let source_rule (rule : Runtime_truth_scc.rule) =
  let source = rule.source in
  { Runtime_witness_proof.identity = source.identity
  ; relation_id = source.relation_id
  ; rule_id = source.rule_id
  ; origin = source.origin
  ; source_echo = source.source_echo
  ; head = source.head
  ; prems = source.prems
  }

let target_chain rule =
  Runtime_witness_proof.target_chain (source_rule rule)

let transitive_domain rule =
  Runtime_witness_proof.transitive_domain (source_rule rule)

let target_chain_seed rule =
  match transitive_domain rule with
  | Some _ -> None
  | None -> target_chain rule

let successor_domain_diagnostics ctx item =
  item.request.plan.Runtime_truth_scc.sccs
  |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
  |> List.filter_map (fun rule ->
    match transitive_domain rule with
    | None -> None
    | Some domain ->
      (match Runtime_truth_scc.successor_domain item.request.plan domain with
      | Some certificate
        when item.request.mode = Runtime_truth_worklist_helper.Prove
             || Runtime_truth_successor_domain.decision_complete certificate ->
        None
      | Some _ ->
        let source = domain.Runtime_witness_proof.rule in
        Some
          (diagnostic ctx item source.origin
             "RuntimeTruthWorklist/transitive-domain/exhaustive-coverage"
             "Decide/refute mode requires an explicit source-rule coverage proof for the exact witness domain; positive successor candidates are not an exhaustive decision domain"
             "Keep false/no-hit Unsupported until every source RuleD of the domain relation is covered by an exact finite candidate theorem"
             source.source_echo)
      | None ->
        let source = domain.Runtime_witness_proof.rule in
        Some
          (diagnostic ctx item source.origin
             "RuntimeTruthWorklist/transitive-domain-certificate"
             "finite transitive false/no-hit materialization reached the boundary without a complete typed successor-domain certificate"
             "Prove the source-derived successor domain, including every nested producer, before requesting runtime truth materialization"
             source.source_echo)))

let same_source_rule source (rule : Runtime_truth_scc.rule) =
  Source_rule_identity.equal_rule source.Runtime_witness_proof.identity
    rule.source.identity

let seed_op item relation =
  Naming.helper_companion
    ~role:("truth-seed-" ^ Naming.source_slug ~lower:true relation.id)
    item.name

let seed_hit_op item relation =
  Naming.helper_companion
    ~role:("truth-seed-hit-" ^ Naming.source_slug ~lower:true relation.id)
    item.name

let seed_miss_op item relation =
  Naming.helper_companion
    ~role:("truth-seed-miss-" ^ Naming.source_slug ~lower:true relation.id)
    item.name

let target_witness_binding relation target term =
  match target.Runtime_witness_proof.recursive_premise.it with
  | RulePr (_, [], _, exp) ->
    let components = Analysis.Relation_graph.exp_components exp in
    (match List.rev components, List.rev relation.sorts with
    | witness_exp :: _, sort :: _ ->
      Some
        ( target.witness_source_id
        , { Expr_env.term; sort; typ = witness_exp.note } )
    | _ -> None)
  | _ -> None

let seed_surface item relation target =
  let known_count = target.Runtime_witness_proof.prefix_arity + 1 in
  match split_at known_count relation.sorts with
  | Some (known_sorts, [ witness_sort ]) ->
    let result =
      sort
        ("RuntimeTruthSeed" ^ Naming.sort_token item.name
         ^ Naming.sort_token relation.id ^ "Conf")
    in
    let sorts = known_sorts @ [ terminals ] in
    Some
      ( result
      , witness_sort
      , [ generated item item.origin (sort_decl result)
        ; generated item item.origin
            (op (seed_op item relation) (List.map sort_ref sorts) result
               ~attrs:(frozen_all sorts))
        ; generated item item.origin
            (op (seed_hit_op item relation) [ sort_ref witness_sort ] result ~attrs:[ Ctor ])
        ]
        @ (match item.request.mode with
           | Runtime_truth_worklist_helper.Prove -> []
           | Decide ->
             [ generated item item.origin
                 (op (seed_miss_op item relation) [] result ~attrs:[ Ctor ]) ]) )
  | _ -> None

let worklist_pattern_certificate ctx item relations =
  let relation_statements =
    relations |> List.concat_map (relation_surface item)
  in
  let seed_statements =
    relations
    |> List.concat_map (fun relation ->
      relation.rules
      |> List.filter_map target_chain_seed
      |> List.filter_map (fun target -> seed_surface item relation target)
      |> List.concat_map (fun (_, _, statements) -> statements))
  in
  surface_pattern_certificate ctx
    (helper_surface item @ positive_phase_surface item
     @ relation_statements @ seed_statements)

let seed_rules ctx item relations relation indexed_rules target =
  match seed_surface item relation target with
  | None -> [], []
  | Some (_seed_sort, _witness_sort, surface) ->
    let known_count = target.Runtime_witness_proof.prefix_arity + 1 in
    let rules =
      indexed_rules
      |> List.filter (fun (_, rule) -> not (same_source_rule target.rule rule))
      |> List.map (fun (rule_index, rule) ->
        let origin, declarations, bind_diags, head =
          Runtime_truth_worklist_rule.lower_head
            ctx item relation rule_index rule
        in
        match head.terms with
        | None -> [], bind_diags @ head.diagnostics
        | Some terms ->
          (match split_at known_count terms with
          | Some (known, [ witness ]) ->
            let history, _ = history_var head.local_names in
            let children =
              lower_positive_children ctx item relations origin
                Runtime_truth_worklist_indexed.Seed_premise rule_index
                known head.env history
                (Runtime_truth_scc.scheduled_premises rule)
            in
            let lhs = App (seed_op item relation, known @ [ history ]) in
            let rhs = App (seed_hit_op item relation, [ witness ]) in
            let head_guards =
              Runtime_truth_worklist_rule.emitted_head_guards
                ctx terms head.guards
            in
            let conditions =
              List.map (fun guard -> EqCondition guard)
                (head_guards @ children.eq_conditions)
              @ children.rule_conditions
              |> Condition_closure.normalize_rule_conditions
                   ~constructor_op:
                     (worklist_pattern_certificate ctx item relations)
                   [ lhs ]
            in
            let diagnostics =
              bind_diags @ head.diagnostics @ children.diagnostics
              @ Condition_admissibility.crl_admissibility_diagnostics
                  ~constructor_op:
                    (worklist_pattern_certificate ctx item relations)
                  ctx origin lhs rhs conditions
            in
            if not children.complete || List.exists Diagnostics.is_fatal diagnostics then
              [], diagnostics
            else
              ( children.statements @ declarations
                @ [ generated item origin
                      (crl
                         ~label:
                           (item.name ^ "-seed-" ^ Naming.sanitize relation.id
                            ^ "-rule-" ^ string_of_int rule_index)
                         lhs rhs conditions) ]
              , diagnostics )
          | _ -> [], bind_diags @ head.diagnostics))
    in
    surface @ List.concat_map fst rules, List.concat_map snd rules

let static_validation_premise ctx prem =
  match prem.it with
  | RulePr (id, args, mixop, exp) ->
    let graph = Context.function_graph ctx in
    (match Analysis.Function_graph.find_relation graph id.it with
    | Some relation ->
      Runtime_validation_certificate.certified
        ~predicate_marker:
          (relation.kind = Analysis.Relation_graph.Predicate_candidate)
        ~source_params:relation.source_params
        ~runtime_demanded:
          (Analysis.Function_graph.relation_is_runtime_demanded graph id.it)
        ~mixop_equal:Il.Eq.eq_mixop
        ~declaration_mixop:relation.mixop
        ~premise_args:args
        ~premise_mixop:mixop
        ~result:relation.result
        ~premise_exp:exp
    | None -> false)
  | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> false

let external_validation_guards ctx env bound_terms origin premises =
  if
    List.for_all
      (fun prem ->
        static_validation_premise ctx prem)
      premises
  then
    premises
    |> List.map (fun prem ->
      Premise_diagnostic.skipped_prem
        ctx env ~bound_vars:[] origin
        "RuntimeTruthWorklist/target-guard/external-validation" prem
        "target-chain guard is discharged by validated initial configuration construction"
        "Retain the source guard in provenance; emit no runtime condition only in the externally validated profile")
    |> List.fold_left Premise_result.append
         (Premise_result.empty_with_env env)
    |> Premise_result.classify
  else
    Premise_translate.translate_premises
      ~allow_runtime_search:false
      ~discharge_static_validation:true
      ctx env ~bound_terms origin premises

type target_guards =
  { true_conditions : rule_condition list
  ; false_conditions : rule_condition list list
  ; diagnostics : Diagnostics.t list
  }

let planned_target_guards rule source_guards =
  let rec take source = function
    | [] -> None
    | guard :: guards when Il.Eq.eq_prem source guard ->
      Some (guard, guards)
    | guard :: guards ->
      Option.map (fun (found, rest) -> found, guard :: rest) (take source guards)
  in
  let rec collect remaining selected = function
    | [] -> if remaining = [] then Some (List.rev selected) else None
    | guard :: guards ->
      (match take (classified_premise_source guard) remaining with
      | Some (_, remaining) -> collect remaining (guard :: selected) guards
      | None -> collect remaining selected guards)
  in
  collect source_guards [] rule.Runtime_truth_scc.premises

let lower_target_guards
    ctx item relations origin env bound_terms history need_false guards =
  let rec lower prefix failures diagnostics = function
    | [] -> Materialized
        { true_conditions = prefix
        ; false_conditions = List.rev failures
        ; diagnostics
        }
    | (Runtime_truth_scc.Finite_rule_call _ as guard) :: rest ->
      (match recursive_call ctx item relations env history guard true with
      | None ->
        edge_blocker ctx item origin
          "RuntimeTruthWorklist/target-chain/guard-positive"
          "target-chain runtime guard has no materializable worklist prove call"
          "Keep the target-chain edge blocked until its planned finite guard has a complete worklist signature"
          (Some (Il.Print.string_of_prem (classified_premise_source guard)))
      | Some (condition, guards, true_diagnostics) ->
        let positive = List.map (fun guard -> EqCondition guard) guards @ [ condition ] in
        if not need_false then
          lower (prefix @ positive) failures
            (diagnostics @ true_diagnostics) rest
        else
          (match recursive_call ctx item relations env history guard false with
          | None ->
            edge_blocker ctx item origin
              "RuntimeTruthWorklist/target-chain/guard-negative"
              "target-chain runtime guard has no exhaustive worklist refute call"
              "Keep decision mode blocked until its planned finite guard has a total worklist decision"
              (Some (Il.Print.string_of_prem (classified_premise_source guard)))
          | Some (condition, guards, false_diagnostics) ->
            let failure =
              prefix @ List.map (fun guard -> EqCondition guard) guards
              @ [ condition ]
            in
            lower (prefix @ positive) (failure :: failures)
              (diagnostics @ true_diagnostics @ false_diagnostics) rest))
    | Runtime_truth_scc.Externally_validated prem :: rest ->
      let result = external_validation_guards ctx env bound_terms origin [ prem ] in
      (match result with
      | Premise_result.Blocked result_diagnostics
      | Deferred (_, result_diagnostics) ->
        Blocked (diagnostics @ result_diagnostics)
      | Complete result ->
        let positive =
          List.map
            (fun guard -> EqCondition guard)
            (Premise_result.eq_conditions result)
          @ Premise_result.rule_conditions result
        in
        lower (prefix @ positive) failures
          (diagnostics @ Premise_result.diagnostics result) rest)
    | guard :: _ ->
      edge_blocker ctx item origin
        "RuntimeTruthWorklist/target-chain/guard-classification"
        "target-chain guard is neither an admitted finite runtime call nor an exact external-validation leaf"
        "Preserve this target chain as Unsupported until the classified guard has source-complete true and false materialization"
        (Some (Il.Print.string_of_prem (classified_premise_source guard)))
  in
  lower [] [] [] guards

let target_chain_edge
    ctx item relations relation rule target head_env head_terms history prove =
  let known_count = target.Runtime_witness_proof.prefix_arity + 1 in
  match split_at known_count head_terms with
  | Some (known, [ target_term ]) ->
    (match target_witness_binding relation target (Const "unused") with
    | None ->
      edge_blocker ctx item target.rule.origin
        "RuntimeTruthWorklist/target-chain/witness-binding"
        "target-chain witness has no carrier binding derived from its recursive RulePr"
        "Keep the finite successor edge blocked until the recursive premise and relation signature agree"
        target.rule.source_echo
    | Some (source_id, binding) ->
      let names = reserve_names head_env [ source_id ] (head_terms @ [ history ]) in
      let witness_name =
        Local_name.source_qualified_name names source_id (sort_ref binding.sort)
      in
      let witness = Var witness_name in
      let binding = { binding with Expr_env.term = witness } in
      let env = Expr_env.add head_env source_id binding in
      let target_premise = target.target_premise in
      (match target_premise.it with
      | RulePr (target_id, [], _, exp) ->
        let lowered =
          Runtime_truth_rule_components.lower_value_components
            ctx env target.rule.origin
            (Analysis.Relation_graph.exp_components exp)
        in
        (match lowered.values with
        | None -> Blocked lowered.diagnostics
        | Some (target_terms, _) ->
          let invocation =
            Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request
          in
          let outcome = if prove then invocation.proved_rhs else invocation.refuted_rhs in
          let target_op = if prove then prove_op item target_id.it else refute_op item target_id.it in
          (match planned_target_guards rule target.guard_premises with
          | None ->
            edge_blocker ctx item target.rule.origin
              "RuntimeTruthWorklist/target-chain/guard-plan"
              "target-chain source guard is absent from the SCC premise plan"
              "Keep the edge blocked until every source guard retains an exact planned premise"
              target.rule.source_echo
          | Some planned_guards ->
            (match
               lower_target_guards
                 ctx item relations target.rule.origin env
                 (known @ [ target_term; witness ]) history (not prove)
                 planned_guards
             with
            | Blocked diagnostics -> Blocked (lowered.diagnostics @ diagnostics)
            | Materialized guards ->
              let seed =
                RewriteCond
                  (App (seed_op item relation, known @ [ history ]),
                   App (seed_hit_op item relation, [ witness ]))
              in
              let target_condition =
                RewriteCond
                  (App (target_op, target_terms @ [ history ]), outcome)
              in
              let alternatives =
                if prove then
                  [ seed
                    :: guards.true_conditions
                    @ List.map (fun guard -> EqCondition guard) lowered.guards
                    @ [ target_condition ] ]
                else
                  [ [ RewriteCond
                        ( App (seed_op item relation, known @ [ history ])
                        , Const (seed_miss_op item relation) ) ] ]
                  @ List.map (fun failure -> seed :: failure)
                      guards.false_conditions
                  @ [ seed
                      :: guards.true_conditions
                      @ List.map (fun guard -> EqCondition guard) lowered.guards
                      @ [ target_condition ] ]
              in
              Materialized
                ( []
                , alternatives
                , lowered.diagnostics @ guards.diagnostics ))))
      | _ ->
        edge_blocker ctx item target.rule.origin
          "RuntimeTruthWorklist/target-chain/target-premise"
          "target-chain certificate does not end in a plain RulePr"
          "Keep the edge blocked until the source target premise is directly materializable"
          target.rule.source_echo))
  | _ ->
    edge_blocker ctx item target.rule.origin
      "RuntimeTruthWorklist/target-chain/head-arity"
      "target-chain RuleD head does not match its certified prefix/endpoint arity"
      "Keep the edge blocked until the source head and certificate agree"
      target.rule.source_echo

let transitive_edge ctx item relations relation rule identity transitive
    head_env head_terms history prove_mode =
  Runtime_truth_transitive_edge.transitive_edge
    ~static_validation_premise ~external_validation_guards
    ~ctx ~item ~relations ~relation ~rule ~identity ~transitive
    ~head_env ~head_terms ~history ~prove_mode
