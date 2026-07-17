open Util.Source

type blocker =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; source_echo : string option
  }

type t =
  | Supported
  | Blocked of blocker list

let blocker ?source_echo origin constructor reason =
  { origin; constructor; reason; source_echo }

let blocked ?source_echo origin constructor reason =
  Blocked [ blocker ?source_echo origin constructor reason ]

let blocker_reason blocker = blocker.reason

let diagnostic ctx blocker =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:blocker.origin
    ~constructor:blocker.constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) blocker.origin)
    ~profile:(Context.profile_name ctx)
    ~reason:blocker.reason
    ~suggestion:
      "Keep this dependent false edge blocked until the source AST has a total Boolean/equality observer certificate"
    ?source_echo:blocker.source_echo
    ()

let relation_origin ctx rel_id =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id with
  | Some relation -> relation.origin
  | None -> Origin.synthetic ~ast_constructor:"RelD" rel_id

let source_rule_relation_id rule =
  rule.Analysis.Function_graph.relation_id

let same_source_rule
    (source_rule : Runtime_witness_proof.source_rule)
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  Source_rule_identity.equal_rule source_rule.identity rule.identity

let local_relation_rules rel_id rules =
  rules
  |> List.filter (fun rule ->
    String.equal (source_rule_relation_id rule) rel_id)

let rule_text rel_id (rule : Analysis.Function_graph.runtime_search_rule) =
  match rule.rule_id with
  | Some id -> "RuleD `" ^ id ^ "` in relation `" ^ rel_id ^ "`"
  | None -> "source RuleD in relation `" ^ rel_id ^ "`"

let is_supported = function
  | Supported -> true
  | Blocked _ -> false

let blockers = function
  | Supported -> []
  | Blocked blockers -> blockers

let all supports =
  if List.for_all is_supported supports then
    Supported
  else
    Blocked (List.concat_map blockers supports)

let witness_space_blockers fallback_origin blockers =
  blockers
  |> List.map (fun (blocker : Runtime_witness_space.blocker) ->
    { origin = Option.value ~default:fallback_origin blocker.origin
    ; constructor = blocker.constructor
    ; reason = blocker.reason
    ; source_echo = blocker.source_echo
    })

let totality_blockers blockers =
  blockers
  |> List.map (fun (blocker : Runtime_truth_totality.blocker) ->
    { origin = blocker.origin
    ; constructor = blocker.constructor
    ; reason = blocker.reason
    ; source_echo = blocker.source_echo
    })

let rec for_rel ctx seen closure rules rel_id =
  let origin = relation_origin ctx rel_id in
  if List.mem rel_id seen then
    match
      Runtime_witness_space.proof_for_truth_relation ~rel_id ~closure ~rules
    with
    | Ok proof ->
      (match Runtime_witness_proof.recursion proof with
      | Runtime_witness_proof.Acyclic -> Supported
      | Runtime_witness_proof.Finite_transitive _ ->
        blocked origin
          "RuntimeTruthDecisionFalseSupport/ownership/finite-transitive"
          "finite-transitive false semantics is exclusively owned by the SCC worklist engine"
      | Runtime_witness_proof.Target_guided_self _ ->
        blocked
          origin
          "RuntimeTruthDecisionFalseSupport/recursive-revisit"
          ("recursive runtime truth false-support dependency revisits relation `"
           ^ rel_id
           ^ "`"))
    | Error blockers -> Blocked (witness_space_blockers origin blockers)
  else
    match
      Runtime_witness_space.proof_for_truth_relation ~rel_id ~closure ~rules
    with
    | Error blockers -> Blocked (witness_space_blockers origin blockers)
    | Ok proof ->
      (match Runtime_witness_proof.recursion proof with
      | Runtime_witness_proof.Acyclic ->
        acyclic ctx (rel_id :: seen) closure rules rel_id
      | Runtime_witness_proof.Target_guided_self target ->
        target_guided ctx (rel_id :: seen) closure rules target
      | Runtime_witness_proof.Finite_transitive domain ->
        finite_transitive ctx (rel_id :: seen) closure rules rel_id domain)

and acyclic ctx seen closure rules rel_id =
  match local_relation_rules rel_id rules with
  | [] ->
    blocked
      (relation_origin ctx rel_id)
      "RuntimeTruthDecisionFalseSupport/no-local-rule"
      ("relation `" ^ rel_id ^ "` has no local source rules to refute")
  | local_rules ->
    local_rules
    |> List.map (rule ctx ~allow_self:false seen closure rules rel_id)
    |> all

and target_guided ctx seen closure rules target =
  for_rel
    ctx
    seen
    closure
    rules
    target.Runtime_witness_proof.target_rel_id

and premise ctx ~allow_self seen closure rules rel_id env rule_origin prem =
  let prem_origin =
    Origin.with_child
      ~source_echo:(Il.Print.string_of_prem prem)
      rule_origin "premise" ~ast_constructor:"Premise" prem.at
  in
  match prem.it with
  | Il.Ast.IfPr exp ->
    (match
       Runtime_truth_condition_complement.source_boolean_alternatives
         ctx env prem_origin exp
     with
    | Ok proof
      when proof.failures <> []
           && not (List.exists Diagnostics.is_fatal proof.diagnostics) ->
      Supported
    | Ok proof when proof.failures = [] ->
      blocked
        ~source_echo:(Il.Print.string_of_prem prem)
        prem_origin
        "RuntimeTruthDecisionFalseSupport/IfPr/no-failure-alternative"
        "source IfPr totality proof produced no false alternative"
    | Ok _ ->
      blocked
        ~source_echo:(Il.Print.string_of_prem prem)
        prem_origin
        "RuntimeTruthDecisionFalseSupport/IfPr/fatal-lowering"
        "source IfPr totality proof retained a fatal lowering diagnostic"
    | Error blockers -> Blocked (totality_blockers blockers))
  | Il.Ast.RulePr (dep_rel_id, [], _, exp) ->
    let dep_rel_id = dep_rel_id.it in
    if String.equal dep_rel_id rel_id then
      if allow_self then
        Supported
      else
        blocked
          prem_origin
          "RuntimeTruthDecisionFalseSupport/RulePr/recursive"
          ("recursive premise revisits relation `"
           ^ rel_id
           ^ "` without a finite no-hit proof")
    else
      (match Runtime_truth_deterministic_false.check ctx ~rel_id:dep_rel_id ~exp with
      | Runtime_truth_deterministic_false.Supported -> Supported
      | Runtime_truth_deterministic_false.Blocked blockers ->
        Blocked
          (List.map
             (fun blocker ->
               { origin = prem_origin
               ; constructor =
                   "RuntimeTruthDecisionFalseSupport/RulePr/deterministic"
               ; reason =
                   "deterministic RulePr premise for relation `"
                   ^ dep_rel_id
                   ^ "` has no source-complete false support: "
                   ^ blocker
               ; source_echo = Some (Il.Print.string_of_prem prem)
               })
             blockers)
      | Runtime_truth_deterministic_false.Not_deterministic ->
        for_rel ctx seen closure rules dep_rel_id)
  | Il.Ast.RulePr (dep_rel_id, _ :: _, _, _) ->
    blocked
      prem_origin
      "RuntimeTruthDecisionFalseSupport/RulePr/parameterized"
      ("parameterized RulePr premise for relation `"
       ^ dep_rel_id.it
       ^ "` has no source-complete false support")
  | Il.Ast.LetPr _ ->
    blocked prem_origin "RuntimeTruthDecisionFalseSupport/LetPr"
      "LetPr false/no-hit support is not source-complete"
  | Il.Ast.ElsePr ->
    blocked prem_origin "RuntimeTruthDecisionFalseSupport/ElsePr"
      "ElsePr nested inside truth refutation is not supported"
  | Il.Ast.IterPr _ ->
    blocked prem_origin "RuntimeTruthDecisionFalseSupport/IterPr"
      "IterPr false/no-hit support is not source-complete"
  | Il.Ast.NegPr _ ->
    blocked prem_origin "RuntimeTruthDecisionFalseSupport/NegPr"
      "NegPr false/no-hit support is not source-complete"

and rule ctx ~allow_self seen closure rules rel_id source_rule =
  let components =
    Analysis.Relation_graph.exp_components source_rule.Analysis.Function_graph.head
  in
  let lowered_head =
    Runtime_truth_rule_components.lower_complete_head_patterns
      Local_name.empty ctx source_rule.origin components
  in
  match lowered_head.terms with
  | None ->
    blocked
      ?source_echo:source_rule.source_echo
      source_rule.origin
      "RuntimeTruthDecisionFalseSupport/RuleD/head"
      "source RuleD head did not lower to a complete AST-derived pattern environment"
  | Some _ when List.exists Diagnostics.is_fatal lowered_head.diagnostics ->
    blocked
      ?source_echo:source_rule.source_echo
      source_rule.origin
      "RuntimeTruthDecisionFalseSupport/RuleD/head"
      "source RuleD head retained a fatal pattern-lowering diagnostic"
  | Some _ ->
    (match source_rule.prems with
    | [] -> Supported
    | prems ->
      prems
      |> List.map
           (premise ctx ~allow_self seen closure rules rel_id
              lowered_head.env source_rule.origin)
      |> all)

and finite_transitive ctx seen closure rules rel_id domain =
  match Runtime_witness_domain.prepare domain with
  | Error blockers ->
    Blocked
      (blockers
       |> List.map (fun (blocker : Runtime_witness_domain.blocker) ->
         { origin = relation_origin ctx rel_id
         ; constructor = blocker.constructor
         ; reason = blocker.reason
         ; source_echo = None
         }))
  | Ok _plan ->
    let transitive_rule = domain.Runtime_witness_proof.transitive.rule in
    let local_rules =
      local_relation_rules rel_id rules
      |> List.filter (fun source_rule ->
        not (same_source_rule transitive_rule source_rule))
    in
    (match local_rules with
    | [] ->
      blocked
        (relation_origin ctx rel_id)
        "RuntimeTruthDecisionFalseSupport/no-local-rule"
        ("relation `" ^ rel_id ^ "` has no local source rules to refute")
    | local_rules ->
      local_rules
      |> List.map (fun source_rule ->
        match rule ctx ~allow_self:true seen closure rules rel_id source_rule with
        | Supported -> Supported
        | Blocked blockers ->
          Blocked
            (List.map
               (fun blocker ->
                 { blocker with
                   reason = rule_text rel_id source_rule ^ ": " ^ blocker.reason
                 })
               blockers))
      |> all)

let check_truth_request ctx truth_request =
  match truth_request.Runtime_truth_search_helper.recursion with
  | Runtime_truth_search_helper.Acyclic ->
    acyclic
      ctx
      []
      truth_request.closure
      truth_request.rules
      truth_request.rel_id
  | Runtime_truth_search_helper.Target_guided_self _
  | Runtime_truth_search_helper.Finite_transitive _ ->
    blocked
      (relation_origin ctx truth_request.rel_id)
      "RuntimeTruthDecisionFalseSupport/ownership/recursive"
      "recursive/transitive false semantics is exclusively owned by the SCC worklist engine"
  | Runtime_truth_search_helper.Recursive _ ->
    blocked
      (relation_origin ctx truth_request.rel_id)
      "RuntimeTruthDecisionFalseSupport/recursive"
      "runtime truth recursion is recursive without a finite no-hit proof"

let check ctx request =
  check_truth_request ctx request.Runtime_truth_decision_helper.truth_request
