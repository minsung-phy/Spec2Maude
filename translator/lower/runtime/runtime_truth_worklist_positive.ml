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

let split_at count values =
  let rec split count left right =
    if count = 0 then Some (List.rev left, right)
    else match right with
      | [] -> None
      | value :: right -> split (count - 1) (value :: left) right
  in
  split count [] values

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
        ] )
  | _ -> None

let worklist_pattern_certificate ctx item relations =
  let relation_statements =
    relations |> List.concat_map (relation_surface item)
  in
  let seed_statements =
    relations
    |> List.concat_map (fun relation ->
      relation.rules
      |> List.filter_map target_chain
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
            let conditions =
              List.map (fun guard -> EqCondition guard)
                (head.guards @ children.eq_conditions)
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

type 'a edge_result =
  | Materialized of 'a
  | Blocked of Diagnostics.t list

let edge_blocker ctx item origin constructor reason suggestion source_echo =
  Blocked [ diagnostic ctx item origin constructor reason suggestion source_echo ]

let classified_premise_source = function
  | Runtime_truth_scc.Finite_rule_call { premise; _ }
  | Finite_domain_call premise
  | Finite_successor_call { premise; _ }
  | Deterministic_total premise
  | Externally_validated premise
  | Source_boolean premise
  | Deterministic_binding_iter premise
  | Finite_iter { premise; _ } -> premise

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
                  List.map (fun failure -> seed :: failure)
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

let successor_op item relation index =
  Naming.helper_companion
    ~role:
      ("truth-successors-" ^ Naming.source_slug ~lower:true relation.id
       ^ "-" ^ string_of_int index)
    item.name

let source_origin item rule =
  Origin.with_child ?source_echo:rule.Analysis.Function_graph.source_echo
    item.origin
    ("successor/" ^ Option.value ~default:"_" rule.rule_id)
    ~ast_constructor:"RuleD" rule.origin.region

let lower_prefix_left ctx item _relation rule arity _index =
  let origin = source_origin item rule in
  let names =
    Reld_rule_lowering.local_names_for_rule_parts
      rule.Analysis.Function_graph.binds rule.head rule.prems
  in
  let env, declarations, bind_diagnostics, names =
    Reld_rule_lowering.translate_rule_binds
      ctx origin names rule.Analysis.Function_graph.binds
  in
  match split_at (arity + 1) (Analysis.Relation_graph.exp_components rule.head) with
  | Some (components, [ _ ]) ->
    let head =
      Runtime_truth_rule_components.lower_complete_head_patterns
        names ~env ctx origin components
    in
    origin, declarations, bind_diagnostics, head
  | _ ->
    origin, declarations, bind_diagnostics,
    { Runtime_truth_rule_components.terms = None
    ; env; guards = []; diagnostics = []; local_names = names }

let bind_direct_components env components terms sorts =
  List.fold_left2
    (fun env (exp : Il.Ast.exp) (term, sort) ->
      match exp.it with
      | VarE id ->
        Expr_env.add env id.it
          { Expr_env.term; sort; typ = exp.note }
      | _ -> env)
    env components (List.combine terms sorts)

let same_search_rule left right =
  Source_rule_identity.equal_rule
    left.Analysis.Function_graph.identity right.Analysis.Function_graph.identity

type certified_prefix_result =
  { env : Expr_env.t
  ; conditions : eq_condition list
  ; diagnostics : Diagnostics.t list
  ; complete : bool
  ; local_names : Local_name.t
  }

let certified_binding bindings prem =
  bindings
  |> List.find_opt (fun binding ->
    Il.Eq.eq_prem binding.Runtime_truth_successor_domain.premise prem)

let lower_certified_prefix names ctx env origin ~bound_terms prefix bindings =
  let source_names =
    Il.Free.(free_prems prefix).varid |> Il.Free.Set.elements
  in
  let names = Local_name.reserve_sources names source_names in
  let names =
    Local_name.reserve_existing_many names
      (Expr_env.bound_vars env
       @ List.concat_map Condition_closure.term_vars bound_terms)
  in
  let rec lower state = function
    | [] -> state
    | prem :: rest ->
      (match certified_binding bindings prem with
      | Some binding ->
        let value = Expr_translate.lower_value ctx state.env origin binding.value in
        let pattern, candidate_names =
          Expr_translate.lower_pattern_with_bindings_named
            state.local_names ctx state.env origin binding.pattern
        in
        (match value.term, pattern.pattern_term with
        | Some value_term, Some pattern_term
          when not (List.exists Diagnostics.is_fatal
                      (value.diagnostics @ pattern.pattern_diagnostics)) ->
          let conditions =
            value.guards @ [ MatchCond (pattern_term, value_term) ]
            @ pattern.pattern_guards
          in
          lower
            { env =
                Premise_state.add_introduced_bindings
                  state.env pattern.introduced_bindings
            ; conditions = state.conditions @ conditions
            ; diagnostics =
                state.diagnostics @ value.diagnostics
                @ pattern.pattern_diagnostics
            ; complete = state.complete
            ; local_names = candidate_names
            }
            rest
        | _ ->
          { state with
            diagnostics =
              state.diagnostics @ value.diagnostics
              @ pattern.pattern_diagnostics
          ; complete = false
          })
      | None ->
        let result, candidate_names =
          Premise_translate.translate_premises_named
            state.local_names
            ~allow_runtime_search:false ~discharge_static_validation:true
            ctx state.env ~bound_conditions:state.conditions ~bound_terms origin [ prem ]
        in
        (match result with
        | Premise_result.Blocked diagnostics
        | Deferred (_, diagnostics) ->
          { state with
            diagnostics = state.diagnostics @ diagnostics
          ; complete = false
          }
        | Complete result ->
          if Premise_result.has_else result
             || Premise_result.rule_conditions result <> []
             || Premise_result.runtime_search_requests result <> []
             || Premise_result.runtime_truth_search_requests result <> []
             || Premise_result.runtime_truth_worklist_requests result <> []
          then
            { state with
              diagnostics = state.diagnostics @ Premise_result.diagnostics result
            ; complete = false
            }
          else
            lower
              { env = Premise_result.env_after result
              ; conditions =
                  state.conditions @ Premise_result.eq_conditions result
              ; diagnostics =
                  state.diagnostics @ Premise_result.diagnostics result
              ; complete = state.complete
              ; local_names = candidate_names
              }
              rest))
  in
  lower
    { env; conditions = []; diagnostics = []; complete = true; local_names = names }
    prefix

let producer_candidate ctx item relation arity call_terms index producer =
  let entry_rule =
    match producer with
    | Runtime_truth_successor_domain.Direct { rule; _ }
    | Query_endpoint { rule; _ }
    | Projection { rule; _ } -> rule
    | Indexed { entry_rule; _ } -> entry_rule
    | Indexed_constructor { rule; _ } -> rule
    | Delegated { entry_rule; _ } -> entry_rule
  in
  let origin, declarations, bind_diagnostics, head =
    lower_prefix_left ctx item relation entry_rule arity index
  in
  match head.terms with
  | None -> Blocked (bind_diagnostics @ head.diagnostics)
  | Some terms ->
    let op_name = successor_op item relation index in
    let known_sorts =
      match split_at (arity + 1) relation.sorts with
      | Some (sorts, [ _ ]) -> sorts
      | _ -> []
    in
    let surface =
      [ generated item origin
          (op op_name (List.map sort_ref known_sorts) terminals
             ~attrs:(frozen_all known_sorts)) ]
    in
    let outer_bound = terms |> List.concat_map Condition_closure.term_vars in
    let outer_head_guards, deferred_head_guards =
      head.guards
      |> List.partition (fun guard ->
           Condition_closure.external_vars_of_conditions outer_bound [ guard ] = [])
    in
    let finish rhs conditions extra_declarations diagnostics =
      let lhs = App (op_name, terms) in
      let conditions =
        outer_head_guards @ conditions
        |> Condition_closure.normalize_binding_conditions
             ~constructor_op:
               (Condition_closure.source_constructor_certificate ctx)
             [ lhs ]
      in
      let diagnostics =
        bind_diagnostics @ head.diagnostics @ diagnostics
        @ Condition_admissibility.ceq_admissibility_diagnostics
            ctx origin lhs rhs conditions
      in
      if List.exists Diagnostics.is_fatal diagnostics then Blocked diagnostics
      else
        Materialized
          ( App (op_name, call_terms)
          , surface @ declarations @ extra_declarations
            @ [ generated item origin (ceq lhs rhs conditions)
              ; generated item origin
                  (eq ~attrs:[ Owise ]
                     (App
                        ( op_name
                        , fst (input_vars Local_name.empty known_sorts) ))
                     (Const "eps"))
              ]
          , diagnostics )
    in
    (match producer with
    | Runtime_truth_successor_domain.Direct { successor; _ }
    | Projection { successor; _ } ->
      if deferred_head_guards <> [] then
        edge_blocker ctx item origin
          "RuntimeTruthWorklist/successor/deferred-head-guard"
          "direct/projection successor head has a guard not bound by its prefix/left producer lhs"
          "Keep admission closed until the certified producer supplies the guard's exact binding site"
          entry_rule.source_echo
      else
        let lowered = Expr_translate.lower_value ctx head.env origin successor in
        (match lowered.term with
        | None -> Blocked (bind_diagnostics @ head.diagnostics @ lowered.diagnostics)
        | Some term -> finish term lowered.guards [] lowered.diagnostics)
    | Indexed { rule; prefix; bindings; source; _ } ->
      let delegated_origin = source_origin item rule in
      let delegated_env, delegated_declarations, delegated_diagnostics, delegated_names =
        if same_search_rule rule entry_rule then head.env, [], [], head.local_names
        else
          let names =
            Reld_rule_lowering.local_names_for_rule_parts
              rule.binds rule.head rule.prems
          in
          Reld_rule_lowering.translate_rule_binds
            ctx delegated_origin names rule.binds
      in
      let delegated_components =
        match split_at (arity + 1) (Analysis.Relation_graph.exp_components rule.head) with
        | Some (components, [ _ ]) -> components
        | _ -> []
      in
      let delegated_env =
        if same_search_rule rule entry_rule then delegated_env
        else bind_direct_components delegated_env delegated_components terms known_sorts
      in
      let prefix_result =
        lower_certified_prefix
          delegated_names ctx delegated_env delegated_origin
          ~bound_terms:terms prefix bindings
      in
      let lowered =
        Expr_translate.lower_sequence ctx prefix_result.env delegated_origin source
      in
      if deferred_head_guards <> [] then
        edge_blocker ctx item delegated_origin
          "RuntimeTruthWorklist/successor/indexed-deferred-head-guard"
          "indexed successor head has a guard not bound by the outer prefix/left producer lhs"
          "Use an indexed producer certificate with an explicit per-element guard binding site"
          rule.source_echo
      else if not prefix_result.complete then
        edge_blocker ctx item delegated_origin
          "RuntimeTruthWorklist/successor/indexed-certified-prefix"
          "finite indexed successor producer did not materialize its certified ordered binding prefix"
          "Keep transitive admission closed until every certified binding is emitted as MatchCond(pattern, deterministic-value)"
          rule.source_echo
      else
        (match lowered.term with
        | None ->
          Blocked
            (delegated_diagnostics @ prefix_result.diagnostics @ lowered.diagnostics)
        | Some source_term ->
          finish source_term
            (prefix_result.conditions @ lowered.guards)
            delegated_declarations
            (delegated_diagnostics @ prefix_result.diagnostics @ lowered.diagnostics))
    | Indexed_constructor
        { rule; prefix; source; index_source_id; index_typ; successor } ->
      let prefix_result =
        Premise_translate.translate_premises
          ~allow_runtime_search:false ~discharge_static_validation:true
          ctx head.env ~bound_terms:terms origin prefix
      in
      (match prefix_result with
      | Premise_result.Blocked diagnostics
      | Deferred (_, diagnostics) -> Blocked diagnostics
      | Complete prefix_result ->
      if Premise_result.rule_conditions prefix_result <> [] then
        edge_blocker ctx item origin
          "RuntimeTruthWorklist/successor/indexed-constructor-rewrite-prefix"
          "indexed-constructor successor producer has a rewrite-dependent premise prefix, so its finite source cannot be materialized as an ordered equational enumeration"
          "Materialize every prefix premise as an ordered total binding before admitting this producer"
          rule.source_echo
      else
        let source_result =
          Expr_translate.lower_sequence
            ctx (Premise_result.env_after prefix_result) origin source
        in
        (match source_result.term with
        | None ->
          Blocked
            (bind_diagnostics @ head.diagnostics
             @ Premise_result.diagnostics prefix_result
             @ source_result.diagnostics)
        | Some source_term ->
          let source_conditions =
            Premise_result.eq_conditions prefix_result @ source_result.guards
          in
          let initial_bound =
            terms |> List.concat_map Condition_closure.term_vars
          in
          let unbound_source =
            Condition_closure.external_vars_of_term_after_conditions
              initial_bound source_term source_conditions
          in
          if unbound_source <> [] then
            edge_blocker ctx item origin
              "RuntimeTruthWorklist/successor/indexed-constructor-symbolic-source"
              ("indexed-constructor source is not ground after its ordered premise prefix; unbound Maude variables: "
               ^ String.concat ", " unbound_source)
              "Bind the complete finite source from the RuleD head or earlier premises before enumerating its positions"
              rule.source_echo
          else
            let successor_ids =
              Il.Free.(free_exp successor).varid |> Il.Free.Set.elements
              |> List.filter (fun id -> not (String.equal id index_source_id))
            in
            let source_env = Premise_result.env_after prefix_result in
            let names =
              reserve_names source_env (index_source_id :: successor_ids)
                (terms @ [ source_term ])
            in
            let capture_candidates =
              Helper_capture.available_capture_candidates source_env successor_ids
            in
            let bound_ids = List.map fst capture_candidates in
            let missing =
              List.filter (fun id -> not (List.mem id bound_ids)) successor_ids
            in
            if missing <> [] then
              edge_blocker ctx item origin
                "RuntimeTruthWorklist/successor/indexed-constructor-symbolic-successor"
                ("indexed-constructor successor depends on variables not bound by the head or ordered premise prefix: "
                 ^ String.concat ", " (List.rev missing))
                "Bind every successor dependency before finite index enumeration"
                rule.source_echo
            else
              let source_captures =
                Helper_capture.make_captures names capture_candidates
              in
              let captures =
                source_captures
                |> List.map (fun capture ->
                  { Runtime_truth_successor_indexed_constructor.call_term =
                      capture.Request.call_term
                  ; formal_var = capture.formal_var
                  ; sort = capture.sort })
              in
              let index_var =
                Local_name.source_qualified_name names index_source_id
                  (sort_ref (sort "Nat"))
              in
              let helper_env =
                Expr_env.add
                  (Helper_capture.capture_env source_captures) index_source_id
                  { term = Var index_var; sort = sort "Nat"; typ = index_typ }
              in
              let lowered_successor =
                Expr_translate.lower_value ctx helper_env origin successor
              in
              (match lowered_successor.term with
              | None ->
                Blocked
                  (bind_diagnostics @ head.diagnostics
                   @ Premise_result.diagnostics prefix_result
                   @ source_result.diagnostics @ lowered_successor.diagnostics)
              | Some successor_term ->
                let head_var, names =
                  Local_name.fresh_qualified_name
                    names Local_name.Head (sort_ref terminal)
                in
                let tail_var, _ =
                  Local_name.fresh_qualified_name
                    names Local_name.Tail (sort_ref terminals)
                in
                let helper =
                  Runtime_truth_successor_indexed_constructor.materialize
                    { helper_name = item.name; origin; index; source_term; captures
                    ; index_var; head_var; tail_var; successor_term
                    ; successor_guards =
                        deferred_head_guards @ lowered_successor.guards }
                in
                finish helper.term source_conditions helper.statements
                  (Premise_result.diagnostics prefix_result
                   @ source_result.diagnostics
                   @ lowered_successor.diagnostics))))
    | Query_endpoint _ ->
      edge_blocker ctx item origin
        "RuntimeTruthWorklist/successor/query-endpoint-boundary"
        "a query-endpoint producer reached the source-expression materializer"
        "Materialize the typed query endpoint directly from the runtime truth request"
        entry_rule.source_echo
    | Delegated _ ->
      edge_blocker ctx item origin
        "RuntimeTruthWorklist/successor/delegated"
        "delegated successor certificate reached the leaf materializer before its typed child producers were expanded"
        "Expand the delegated certificate structurally before materializing its child producers"
        entry_rule.source_echo)

let rec producer_candidates
    ctx item relation arity call_terms query_term
    ~query_endpoint_complete next producer =
  match producer with
  | Runtime_truth_successor_domain.Query_endpoint _
    when item.request.mode = Runtime_truth_worklist_helper.Prove
         || query_endpoint_complete ->
    [ Materialized (query_term, [], []) ], next
  | Runtime_truth_successor_domain.Query_endpoint { rule; _ } ->
    [ edge_blocker ctx item rule.origin
        "RuntimeTruthWorklist/successor/query-endpoint-decide"
        "a query endpoint is a positive candidate only and cannot witness exhaustive absence in Decide/refute mode"
        "Supply an exact source-rule coverage proof and finite decision domain; do not use the requested target as a no-hit fallback"
        rule.source_echo
    ], next
  | Runtime_truth_successor_domain.Delegated
      { producers; _ } ->
    producers
    |> List.fold_left
         (fun (results, next) producer ->
           let nested, next =
             producer_candidates ctx item relation arity call_terms query_term
               ~query_endpoint_complete next producer
           in
           List.rev_append nested results, next)
         ([], next)
    |> fun (results, next) -> List.rev results, next
  | producer ->
    [ producer_candidate ctx item relation arity call_terms next producer ], next + 1

let domain_candidate ctx item env origin source_echo index = function
  | Runtime_truth_successor_domain.Closed_constructor name ->
    Materialized (Const name, [], [])
  | Closed_term exp ->
    let lowered = Expr_translate.lower_value ctx env origin exp in
    (match lowered.term, lowered.guards with
    | Some term, [] -> Materialized (term, [], lowered.diagnostics)
    | Some term, guards ->
      let name =
        Naming.helper_companion
          ~role:("truth-closed-domain-" ^ string_of_int index) item.name
      in
      let lhs = Const name in
      let statements =
        [ generated item origin (op name [] terminal)
        ; generated item origin (ceq lhs term guards)
        ]
      in
      let diagnostics =
        lowered.diagnostics
        @ Condition_admissibility.ceq_admissibility_diagnostics
            ctx origin lhs term guards
      in
      if List.exists Diagnostics.is_fatal diagnostics then Blocked diagnostics
      else Materialized (lhs, statements, diagnostics)
    | None, _ -> Blocked lowered.diagnostics)
  | Indexed_domain
      { source; index_source_id; index_typ; index_constructor; witness } ->
    let source_result = Expr_translate.lower_sequence ctx env origin source in
    (match source_result.term, source_result.guards with
    | Some source_term, [] ->
      let capture_ids =
        Il.Free.(free_exp witness).varid |> Il.Free.Set.elements
        |> List.filter (fun id -> not (String.equal id index_source_id))
      in
      let names =
        reserve_names env (index_source_id :: capture_ids) [ source_term ]
      in
      let capture_candidates =
        Helper_capture.available_capture_candidates env capture_ids
      in
      let bound_ids = List.map fst capture_candidates in
      let missing =
        List.filter (fun id -> not (List.mem id bound_ids)) capture_ids
      in
      if missing <> [] then
        edge_blocker ctx item origin
          "RuntimeTruthWorklist/domain/indexed-capture"
          ("a certified indexed domain witness has unbound captures: "
           ^ String.concat ", " (List.rev missing))
          "Bind every non-index witness component from the transitive RuleD head"
          source_echo
      else
        let source_captures =
          Helper_capture.make_captures names capture_candidates
        in
        let captures =
          source_captures
          |> List.map (fun capture ->
            { Runtime_truth_successor_indexed_constructor.call_term =
                capture.Request.call_term
            ; formal_var = capture.formal_var
            ; sort = capture.sort })
        in
        let index_var =
          Local_name.source_qualified_name names index_source_id
            (sort_ref (sort "Nat"))
        in
        let index_binding =
          match index_constructor with
          | None -> Some (Var index_var, sort "Nat")
          | Some constructor ->
            Option.map
              (fun carrier -> App (constructor, [ Var index_var ]), carrier)
              (Expr_translate.carrier_sort_of_typ index_typ)
        in
        (match index_binding with
        | None ->
          edge_blocker ctx item origin
            "RuntimeTruthWorklist/domain/index-constructor-sort"
            "the exact indexed-domain constructor has no carrier sort"
            "Keep the indexed domain blocked until its typed wrapper is emitted"
            source_echo
        | Some (index_term, index_sort) ->
          let helper_env =
            Expr_env.add
              (Helper_capture.capture_env source_captures) index_source_id
              { term = index_term; sort = index_sort; typ = index_typ }
          in
          let successor = Expr_translate.lower_value ctx helper_env origin witness in
          (match successor.term with
        | None ->
          Blocked (source_result.diagnostics @ successor.diagnostics)
        | Some successor_term ->
          let head_var, names =
            Local_name.fresh_qualified_name
              names Local_name.Head (sort_ref terminal)
          in
          let tail_var, _ =
            Local_name.fresh_qualified_name
              names Local_name.Tail (sort_ref terminals)
          in
          let helper =
            Runtime_truth_successor_indexed_constructor.materialize
              { helper_name = item.name; origin; index; source_term; captures
              ; index_var; head_var; tail_var; successor_term
              ; successor_guards = successor.guards
              }
          in
          Materialized
            (helper.term, helper.statements,
             source_result.diagnostics @ successor.diagnostics)))
    | Some _, _ :: _ ->
      edge_blocker ctx item origin
        "RuntimeTruthWorklist/domain/guarded-index-source"
        "a certified indexed domain source acquired lowering guards"
        "Keep the domain blocked until the complete source sequence is directly bound"
        source_echo
    | None, _ -> Blocked source_result.diagnostics)

let domain_candidates ctx item env origin source_echo candidates =
  candidates
  |> List.mapi (domain_candidate ctx item env origin source_echo)

type transitive_domain_child =
  { declarations : generated list
  ; true_conditions : rule_condition list
  ; false_conditions : rule_condition list list option
  ; diagnostics : Diagnostics.t list
  }

let transitive_domain_child rule
    (transitive : Runtime_witness_proof.transitive_domain) =
  rule.Runtime_truth_scc.premises
  |> List.find_opt (fun premise ->
    Il.Eq.eq_prem (classified_premise_source premise) transitive.Runtime_witness_proof.domain_premise)

let transitive_witness_binding relation
    (transitive : Runtime_witness_proof.transitive_domain) term =
  match transitive.Runtime_witness_proof.domain_premise.it, List.rev relation.sorts with
  | RulePr (_, [], _, exp), sort :: _ ->
    (match List.rev (Analysis.Relation_graph.exp_components exp) with
    | witness :: _ ->
      Some
        ( transitive.witness_source_id
        , { Expr_env.term; sort; typ = witness.note } )
    | [] -> None)
  | (RulePr (_, _ :: _, _, _) | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _), _ ->
    None
  | RulePr (_, [], _, _), [] -> None

let lower_transitive_domain
    ctx item relations relation rule
    (transitive : Runtime_witness_proof.transitive_domain)
    env head_formals history witness need_false =
  match transitive_domain_child rule transitive,
        transitive_witness_binding relation transitive witness with
  | Some (Finite_domain_call _), Some _ ->
    Materialized
      { declarations = []
      ; true_conditions = []
      ; false_conditions = if need_false then Some [] else None
      ; diagnostics = []
      }
  | Some (Finite_rule_call _ as premise), Some (source_id, binding) ->
    let env = Expr_env.add env source_id binding in
    (match recursive_call ctx item relations env history premise true with
    | Some (true_condition, true_guards, true_diagnostics) ->
      if not need_false then
        Materialized
          { declarations = []
          ; true_conditions =
              List.map (fun guard -> EqCondition guard) true_guards @ [ true_condition ]
          ; false_conditions = None
          ; diagnostics = true_diagnostics
          }
      else
        (match recursive_call ctx item relations env history premise false with
      | Some (false_condition, false_guards, false_diagnostics) ->
        Materialized
          { declarations = []
          ; true_conditions =
              List.map (fun guard -> EqCondition guard) true_guards @ [ true_condition ]
          ; false_conditions =
              Some [ List.map (fun guard -> EqCondition guard) false_guards
                     @ [ false_condition ] ]
          ; diagnostics = true_diagnostics @ false_diagnostics
          }
      | None ->
        edge_blocker ctx item transitive.rule.origin
          "RuntimeTruthWorklist/transitive-domain/recursive-child"
          "the certified domain premise has no total refute call"
          "Keep decision mode blocked until the domain relation has a complete worklist signature"
          transitive.rule.source_echo)
    | None ->
      edge_blocker ctx item transitive.rule.origin
        "RuntimeTruthWorklist/transitive-domain/recursive-child"
        "the certified domain premise has no materializable prove call"
        "Keep positive mode Unsupported until the domain relation has a complete worklist signature"
        transitive.rule.source_echo)
  | Some (Deterministic_total premise), Some (source_id, binding)
    when static_validation_premise ctx premise ->
    let env = Expr_env.add env source_id binding in
    let result =
      external_validation_guards
        ctx env (head_formals @ [ witness ]) transitive.rule.origin [ premise ]
    in
    (match result with
    | Premise_result.Blocked diagnostics
    | Deferred (_, diagnostics) -> Blocked diagnostics
    | Complete result ->
      Materialized
        { declarations = []
        ; true_conditions =
            List.map
              (fun guard -> EqCondition guard)
              (Premise_result.eq_conditions result)
            @ Premise_result.rule_conditions result
        ; false_conditions = if need_false then Some [] else None
        ; diagnostics = Premise_result.diagnostics result
        })
  | Some (Deterministic_total premise), Some (source_id, binding) ->
    let env = Expr_env.add env source_id binding in
    let result =
      Premise_translate.translate_premises
        ~allow_runtime_search:false ~discharge_static_validation:true
        ctx env ~bound_terms:(head_formals @ [ witness ])
        transitive.rule.origin [ premise ]
    in
    (match result with
    | Premise_result.Blocked diagnostics
    | Deferred (_, diagnostics) -> Blocked diagnostics
    | Complete result ->
      if Premise_result.has_else result
         || Premise_result.runtime_search_requests result <> []
         || Premise_result.runtime_truth_search_requests result <> []
         || Premise_result.runtime_truth_worklist_requests result <> []
      then Blocked (Premise_result.diagnostics result)
      else
      Materialized
        { declarations = []
        ; true_conditions =
            List.map
              (fun guard -> EqCondition guard)
              (Premise_result.eq_conditions result)
            @ Premise_result.rule_conditions result
        ; false_conditions = None
        ; diagnostics = Premise_result.diagnostics result
        })
  | Some (Finite_successor_call _ | Externally_validated _
         | Source_boolean _ | Deterministic_binding_iter _ | Finite_iter _), _
  | None, _ | _, None ->
    edge_blocker ctx item transitive.rule.origin
      "RuntimeTruthWorklist/transitive-domain/classified-child"
      "the exact certified transitive RuleD does not retain its domain premise as a ground SCC child or external-validation discharge"
      "Bind only the certificate witness, then classify and materialize the original domain premise before the recursive AND children"
      transitive.rule.source_echo

let transitive_edge
    ctx item relations relation rule identity
    (transitive : Runtime_witness_proof.transitive_domain)
    head_env head_terms history prove_mode =
  match Runtime_truth_scc.successor_domain item.request.plan transitive with
  | None ->
    edge_blocker ctx item transitive.rule.origin
      "RuntimeTruthWorklist/transitive-domain/certificate"
      "transitive RuleD has no source-complete finite successor certificate"
      "Construct every direct, projection, and finite indexed successor producer before admitting this transitive edge"
      transitive.rule.source_echo
  | Some domain ->
    (match split_at transitive.prefix_arity head_terms with
    | Some (prefix, [ left; right ]) ->
      let known = prefix @ [ left ] in
      let producers =
        match domain.Runtime_truth_successor_domain.domain_candidates with
        | _ :: _ as candidates ->
          domain_candidates ctx item head_env transitive.rule.origin
            transitive.rule.source_echo candidates
        | [] ->
          domain.producers
          |> List.fold_left
               (fun (results, next) producer ->
                 let children, next =
                   producer_candidates
                     ctx item relation transitive.prefix_arity known right
                     ~query_endpoint_complete:
                       (Runtime_truth_successor_domain.decision_complete domain)
                     next producer
                 in
                 List.rev_append children results, next)
               ([], 0)
          |> fun (results, _) -> List.rev results
      in
      let diagnostics = producers |> List.concat_map (function
        | Materialized (_, _, diagnostics) | Blocked diagnostics -> diagnostics)
      in
      if List.exists (function Blocked _ -> true | Materialized _ -> false) producers then
        Blocked diagnostics
      else
        let candidates =
          producers |> List.filter_map (function
            | Materialized (call, _, _) -> Some call | Blocked _ -> None)
          |> function
            | [] -> Const "eps"
            | call :: calls ->
              List.fold_left (fun left right -> App ("_ _", [ left; right ])) call calls
        in
        let statements = producers |> List.concat_map (function
          | Materialized (_, statements, _) -> statements | Blocked _ -> [])
        in
        let invocation =
          Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request
        in
        let names = reserve_names head_env [] (head_terms @ [ history ]) in
        let captures, names =
          List.map2 (fun term sort -> term, sort) head_terms relation.sorts
          @ [ history, terminals ]
          |> List.fold_left
               (fun (captures, names) (call_term, sort) ->
                 let formal_var, names =
                   Local_name.fresh_qualified_name
                     names Local_name.Capture (sort_ref sort)
                 in
                 ( { Runtime_truth_worklist_indexed.call_term
                   ; formal_var
                   ; sort }
                   :: captures
                 , names ))
               ([], names)
          |> fun (captures, names) -> List.rev captures, names
        in
        let formals = List.map (fun capture -> Var capture.Runtime_truth_worklist_indexed.formal_var) captures in
        (match split_at transitive.prefix_arity formals with
        | Some (formal_prefix, [ formal_left; formal_right; formal_history ]) ->
          let support_head_var, names =
            Local_name.fresh_qualified_name
              names Local_name.Head (sort_ref terminal)
          in
          let support_tail_var, names =
            Local_name.fresh_qualified_name
              names Local_name.Tail (sort_ref terminals)
          in
          let indexed_head_var, names =
            Local_name.fresh_qualified_name
              names Local_name.Head (sort_ref terminal)
          in
          let indexed_tail_var, _ =
            Local_name.fresh_qualified_name
              names Local_name.Tail (sort_ref terminals)
          in
          let witness = Var indexed_head_var in
          let head_components =
            Analysis.Relation_graph.exp_components transitive.rule.head
          in
          let formal_head = formal_prefix @ [ formal_left; formal_right ] in
          let formal_env =
            bind_direct_components head_env head_components formal_head relation.sorts
          in
          (match
             lower_transitive_domain
               ctx item relations relation rule transitive formal_env formal_head
               formal_history witness
               (item.request.mode = Runtime_truth_worklist_helper.Decide)
           with
          | Blocked diagnostics -> Blocked diagnostics
          | Materialized domain_child ->
            (match prove_mode, domain_child.false_conditions with
            | false, None ->
              edge_blocker ctx item transitive.rule.origin
                "RuntimeTruthWorklist/transitive-domain/false"
                "the domain premise has a positive lowering but no exhaustive false edge"
                "Keep false blocked until every domain-premise alternative is source-completely refutable"
                transitive.rule.source_echo
            | _ ->
          let prove terms = RewriteCond
              (App (prove_op item relation.id, terms @ [ formal_history ]), invocation.proved_rhs) in
          let refute terms = RewriteCond
              (App (refute_op item relation.id, terms @ [ formal_history ]), invocation.refuted_rhs) in
          let left_goal = formal_prefix @ [ formal_left; witness ] in
          let right_goal = formal_prefix @ [ witness; formal_right ] in
          let indexed = Runtime_truth_transitive_materializer.materialize
              { helper_name = item.name; origin = transitive.rule.origin
              ; identity; mode = indexed_mode item; candidates; captures
              ; support_head_var; support_tail_var
              ; indexed_head_var; indexed_tail_var
              ; domain_true = domain_child.true_conditions
              ; domain_false = Option.value ~default:[] domain_child.false_conditions
              ; left_true = prove left_goal; right_true = prove right_goal
              ; left_false = refute left_goal; right_false = refute right_goal
              ; result_sort = result_sort item; proved = invocation.proved_rhs
              ; refuted = invocation.refuted_rhs }
          in
          Materialized
            ( { indexed with
                statements = statements @ domain_child.declarations @ indexed.statements }
            , diagnostics @ domain_child.diagnostics )))
        | _ -> edge_blocker ctx item transitive.rule.origin
            "RuntimeTruthWorklist/transitive-domain/formals"
            "finite successor certificate formals do not match the transitive head"
            "Keep the edge blocked until certificate and relation arities agree"
            transitive.rule.source_echo)
    | _ -> edge_blocker ctx item transitive.rule.origin
        "RuntimeTruthWorklist/transitive-domain/head"
        "finite successor certificate does not match the transitive RuleD head"
        "Keep the edge blocked until certificate and source head agree"
        transitive.rule.source_echo)

module Positive_rule : sig
  val lower :
    Context.t -> item -> relation list -> relation -> int ->
    Runtime_truth_scc.rule -> generated list * Diagnostics.t list
end = struct

let lower ctx item relations relation index rule =
  let origin, declarations, bind_diagnostics, head =
    Runtime_truth_worklist_rule.lower_head ctx item relation index rule
  in
  match head.terms with
  | None -> [], bind_diagnostics @ head.diagnostics
  | Some terms ->
    let history, _ = history_var head.local_names in
    let next_history = push item relation terms history in
    let special_edge, special_blocked =
      match transitive_domain rule with
      | Some transitive ->
        ( (match
             transitive_edge ctx item relations relation rule
               { Runtime_truth_worklist_indexed.phase =
                   Runtime_truth_worklist_indexed.Transitive
               ; rule_index = index
               ; premise_index = None
               }
               transitive head.env terms next_history true
           with
          | Materialized
              ((indexed : Runtime_truth_worklist_indexed.result), diagnostics) ->
            Some (indexed.statements, [ indexed.true_condition ], diagnostics), None
          | Blocked diagnostics -> None, Some diagnostics) )
      | None ->
        (match target_chain rule with
        | None -> None, None
        | Some target ->
          ( (match
               target_chain_edge
                 ctx item relations relation rule target head.env terms next_history true
             with
            | Materialized (statements, [ conditions ], diagnostics) ->
              Some (statements, conditions, diagnostics), None
            | Materialized (_, _, diagnostics) ->
              None, Some
                (diagnostics @ [ diagnostic ctx item origin
                   "RuntimeTruthWorklist/target-chain/positive-alternatives"
                   "target-chain prove edge did not produce exactly one source conjunction"
                   "Keep the edge blocked until its planned guards retain one ordered positive path"
                   rule.source.source_echo ])
            | Blocked diagnostics -> None, Some diagnostics) ))
    in
    let children =
      match special_edge with
      | None when special_blocked = None ->
        lower_positive_children
          ctx item relations origin Runtime_truth_worklist_indexed.Rule_premise
          index terms head.env next_history
          (Runtime_truth_scc.scheduled_premises rule)
      | None ->
        { env = head.env
        ; eq_conditions = []
        ; rule_conditions = []
        ; diagnostics =
            Option.value ~default:[] special_blocked
        ; statements = []
        ; complete = false
        }
      | Some (edge_statements, edge_conditions, edge_diagnostics) ->
        { env = head.env
        ; eq_conditions = []
        ; rule_conditions = edge_conditions
        ; diagnostics = edge_diagnostics
        ; statements = edge_statements
        ; complete = true
        }
    in
    if not children.complete then
      let blockers =
        if children.diagnostics <> [] then []
        else
          [ diagnostic ctx item origin
              "RuntimeTruthWorklist/positive/open-child"
              "source RuleD contains a premise whose finite positive worklist edge is not materialized"
              "Keep this SCC query Unsupported until every ordered AND child has a finite edge"
              rule.source.source_echo ]
      in
      ( []
      , bind_diagnostics @ head.diagnostics @ children.diagnostics @ blockers )
    else
      let phase =
        match transitive_domain rule with
        | None -> Ordinary
        | Some _ -> Transitive
      in
      let lhs =
        App
          ( positive_worker_op item relation.id
          , positive_phase_term item phase :: terms @ [ history ] )
      in
      let rhs = (Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request).proved_rhs in
      let conditions =
        EqCondition
          (BoolCond
             (App
                ("_=/=_",
                 [ visited item relation terms history; Const "true" ])))
        :: List.map (fun guard -> EqCondition guard)
             (head.guards @ children.eq_conditions)
        @ children.rule_conditions
        |> Condition_closure.normalize_rule_conditions
             ~constructor_op:
               (worklist_pattern_certificate ctx item relations)
             [ lhs ]
      in
      let admissibility =
        Condition_admissibility.crl_admissibility_diagnostics
          ~constructor_op:(worklist_pattern_certificate ctx item relations)
          ctx origin lhs rhs conditions
      in
      let diagnostics =
        bind_diagnostics @ head.diagnostics @ children.diagnostics @ admissibility
      in
      if List.exists Diagnostics.is_fatal diagnostics then [], diagnostics
      else children.statements @ declarations
           @ [ generated item origin (crl ~label:(item.name ^ "-prove-" ^ string_of_int index) lhs rhs conditions) ], diagnostics

end
