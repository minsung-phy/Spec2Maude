open Maude_ir
open Il.Ast
open Util.Source

open Runtime_truth_worklist_core
open Runtime_truth_worklist_premise

module Request = Helper_request

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

type successor_candidate =
  { call : term
  ; statements : generated list
  ; diagnostics : Diagnostics.t list
  ; certifies_edge : bool
  }

let classify_candidate certifies_edge = function
  | Materialized (call, statements, diagnostics) ->
    Materialized { call; statements; diagnostics; certifies_edge }
  | Blocked diagnostics -> Blocked diagnostics

let producer_certifies_edge = function
  (* A producer is an edge certificate only after all of that RuleD's other
     premises have been discharged by its producer-specific lowering. *)
  | Runtime_truth_successor_domain.Direct { rule; _ } -> rule.prems = []
  | Projection { rule; premise; _ } ->
    (match rule.prems with
    | [ source ] -> Il.Eq.eq_prem source premise
    | [] | _ :: _ :: _ -> false)
  | Indexed _ | Indexed_constructor _ -> true
  | Query_endpoint _ | Delegated _ -> false

let exact_delegation entry_rule premise =
  match entry_rule.Analysis.Function_graph.prems with
  | [ source ] -> Il.Eq.eq_prem source premise
  | [] | _ :: _ :: _ -> false

let rec producer_candidates
    ctx item relation arity call_terms query_term
    ~query_endpoint_complete ~certifies_entry next producer =
  match producer with
  | Runtime_truth_successor_domain.Query_endpoint _
    when item.request.mode = Runtime_truth_worklist_helper.Prove
         || query_endpoint_complete ->
    [ Materialized
        { call = query_term
        ; statements = []
        ; diagnostics = []
        ; certifies_edge = false
        }
    ], next
  | Runtime_truth_successor_domain.Query_endpoint { rule; _ } ->
    [ edge_blocker ctx item rule.origin
        "RuntimeTruthWorklist/successor/query-endpoint-decide"
        "a query endpoint is a positive candidate only and cannot witness exhaustive absence in Decide/refute mode"
        "Supply an exact source-rule coverage proof and finite decision domain; do not use the requested target as a no-hit fallback"
        rule.source_echo
    ], next
  | Runtime_truth_successor_domain.Delegated
      { entry_rule; premise; producers; _ } ->
    let certifies_entry =
      certifies_entry && exact_delegation entry_rule premise
    in
    producers
    |> List.fold_left
         (fun (results, next) producer ->
           let nested, next =
             producer_candidates ctx item relation arity call_terms query_term
               ~query_endpoint_complete ~certifies_entry next producer
           in
           List.rev_append nested results, next)
         ([], next)
    |> fun (results, next) -> List.rev results, next
  | producer ->
    [ producer_candidate ctx item relation arity call_terms next producer
      |> classify_candidate
           (certifies_entry && producer_certifies_edge producer)
    ], next + 1

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
    ~static_validation_premise ~external_validation_guards
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

let transitive_successors
    ctx item relation
    (transitive : Runtime_witness_proof.transitive_domain)
    (domain : Runtime_truth_successor_domain.t)
    env prefix right current =
  let fixed =
    domain_candidates ctx item env transitive.rule.origin
      transitive.rule.source_echo domain.domain_candidates
    |> List.map (classify_candidate false)
  in
  let known = prefix @ [ current ] in
  let produced =
    domain.producers
    |> List.fold_left
         (fun (results, next) producer ->
           let children, next =
             producer_candidates
               ctx item relation transitive.prefix_arity known right
               ~query_endpoint_complete:
                 (Runtime_truth_successor_domain.decision_complete domain)
               ~certifies_entry:true next producer
           in
           List.rev_append children results, next)
         ([], 0)
    |> fun (results, _) -> List.rev results
  in
  let candidates = fixed @ produced in
  let diagnostics =
    candidates |> List.concat_map (function
      | Materialized (candidate : successor_candidate) -> candidate.diagnostics
      | Blocked diagnostics -> diagnostics)
  in
  if List.exists (function Blocked _ -> true | Materialized _ -> false) candidates
  then Blocked diagnostics
  else
    Materialized
      (candidates |> List.filter_map (function
        | Materialized (candidate : successor_candidate) -> Some candidate
        | Blocked _ -> None))

let transitive_edge
    ~static_validation_premise ~external_validation_guards
    ~ctx ~item ~relations ~relation ~rule ~identity
    ~(transitive : Runtime_witness_proof.transitive_domain)
    ~head_env ~head_terms ~history ~prove_mode =
  match Runtime_truth_scc.successor_domain item.request.plan transitive with
  | None ->
    edge_blocker ctx item transitive.rule.origin
      "RuntimeTruthWorklist/transitive-domain/certificate"
      "transitive RuleD has no source-complete finite successor certificate"
      "Construct every direct, projection, and finite indexed successor producer before admitting this transitive edge"
      transitive.rule.source_echo
  | Some domain ->
    (match split_at transitive.prefix_arity head_terms with
    | Some (_, [ left; _ ]) ->
      let invocation =
        Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request
      in
      let worklist, scope =
        Runtime_truth_transitive_materializer.create
          ~helper_name:item.name ~identity ~env:head_env
          ~terms:head_terms ~sorts:relation.sorts ~history
      in
      (match
         split_at transitive.prefix_arity
           (Runtime_truth_transitive_materializer.scope_formals scope)
       with
      | Some (formal_prefix, [ formal_left; formal_right; formal_history ]) ->
          let witness =
            Runtime_truth_transitive_materializer.scope_witness scope
          in
          let current =
            Runtime_truth_transitive_materializer.scope_current scope
          in
          let head_components =
            Analysis.Relation_graph.exp_components transitive.rule.head
          in
          let formal_head = formal_prefix @ [ formal_left; formal_right ] in
          let formal_env =
            bind_direct_components head_env head_components formal_head relation.sorts
          in
          (match
             transitive_successors
               ctx item relation transitive domain formal_env formal_prefix
               formal_right current
           with
          | Blocked diagnostics -> Blocked diagnostics
          | Materialized materialized ->
            let diagnostics =
              materialized
              |> List.concat_map (fun (candidate : successor_candidate) ->
                   candidate.diagnostics)
            in
            let candidates =
              materialized
              |> List.map (fun (candidate : successor_candidate) -> candidate.call)
            in
            let certified_successors =
              materialized
              |> List.filter_map (fun (candidate : successor_candidate) ->
                   if candidate.certifies_edge then Some candidate.call else None)
            in
            let statements =
              materialized
              |> List.concat_map (fun (candidate : successor_candidate) ->
                   candidate.statements)
            in
            (match
               lower_transitive_domain
                 ~static_validation_premise ~external_validation_guards
                 ctx item relations relation rule transitive formal_env formal_head
                 formal_history witness
                 (item.request.mode = Runtime_truth_worklist_helper.Decide)
             with
            | Blocked domain_diagnostics ->
              Blocked (diagnostics @ domain_diagnostics)
            | Materialized domain_child ->
              (match prove_mode, domain_child.false_conditions with
              | false, None ->
                edge_blocker ctx item transitive.rule.origin
                  "RuntimeTruthWorklist/transitive-domain/false"
                  "the domain premise has a positive lowering but no exhaustive false edge"
                  "Keep false blocked until every domain-premise alternative is source-completely refutable"
                  transitive.rule.source_echo
              | _ ->
                let direct_goal = formal_prefix @ [ current; witness ] in
                let direct_true =
                  RewriteCond
                    ( App
                        ( positive_worker_op item relation.id
                        , positive_phase_term item Ordinary
                          :: direct_goal @ [ formal_history ] )
                    , invocation.proved_rhs )
                in
                let direct_false =
                  RewriteCond
                    ( App
                        ( base_refute_op item relation.id
                        , direct_goal @ [ formal_history ] )
                    , invocation.refuted_rhs )
                in
                let request =
                  Runtime_truth_transitive_materializer.request
                    ~worklist ~origin:transitive.rule.origin
                    ~mode:(indexed_mode item)
                    ~candidates ~certified_successors
                    ~start:left ~target:formal_right
                    ~domain_true:domain_child.true_conditions
                    ~domain_false:
                      (Option.value ~default:[] domain_child.false_conditions)
                    ~direct_true ~direct_false
                    ~result_sort:(result_sort item)
                    ~proved:invocation.proved_rhs
                    ~refuted:invocation.refuted_rhs
                in
                let indexed =
                  Runtime_truth_transitive_materializer.materialize request
                in
                Materialized
                  ( { indexed with
                      statements =
                        statements @ domain_child.declarations
                        @ indexed.statements
                    }
                  , diagnostics @ domain_child.diagnostics ))))
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
