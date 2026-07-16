type result =
  { statements : Maude_ir.generated list
  ; conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  }

type blocker_kind =
  | Relation_local
  | Dependent_truth_decision
  | Parameterized_rulepr
  | Rule_refuter
  | Deterministic_premise
  | Target_local_no_hit
  | Finite_candidate_no_hit
  | Recursive_no_hit
  | Source_construct

type blocker =
  { kind : blocker_kind
  ; text : string
  }

let empty diagnostics =
  { statements = []; conditions = []; diagnostics }

let of_no_hit_result (result : Runtime_truth_no_hit_materializer.result) =
  match result with
  | Complete complete ->
    { statements =
        Runtime_truth_no_hit_materializer.complete_statements complete
    ; conditions =
        Runtime_truth_no_hit_materializer.complete_conditions complete
    ; diagnostics =
        Runtime_truth_no_hit_materializer.complete_diagnostics complete
    }
  | Blocked diagnostics -> empty diagnostics

let blocker kind text =
  { kind; text }

let rule_name index (rule : Analysis.Function_graph.runtime_search_rule) =
  match rule.rule_id with
  | Some id -> "RuleD `" ^ id ^ "`"
  | None -> "RuleD[" ^ string_of_int index ^ "]"

let premise_name index prem =
  "premise[" ^ string_of_int index ^ "] `" ^ Il.Print.string_of_prem prem ^ "`"

let constructor_of_kind = function
  | Relation_local -> "RuntimeTruthDecision/refutation/relation-local"
  | Dependent_truth_decision ->
    "RuntimeTruthDecision/refutation/dependent-truth-decision-missing"
  | Parameterized_rulepr ->
    "RuntimeTruthDecision/refutation/RulePr/args"
  | Rule_refuter -> "RuntimeTruthDecision/refutation/per-RuleD-refuter-missing"
  | Deterministic_premise ->
    "RuntimeTruthDecision/refutation/deterministic-premise-complement-missing"
  | Target_local_no_hit ->
    "RuntimeTruthDecision/refutation/target-local-existential-no-hit-missing"
  | Finite_candidate_no_hit ->
    "RuntimeTruthDecision/refutation/finite-candidate-no-hit-missing"
  | Recursive_no_hit -> "RuntimeTruthDecision/refutation/recursive-no-hit-missing"
  | Source_construct -> "RuntimeTruthDecision/refutation/source-construct"

let blocker_priority = function
  | Relation_local -> 0
  | Dependent_truth_decision -> 1
  | Parameterized_rulepr -> 2
  | Target_local_no_hit -> 3
  | Finite_candidate_no_hit -> 4
  | Deterministic_premise -> 5
  | Rule_refuter -> 6
  | Recursive_no_hit -> 7
  | Source_construct -> 8

let primary_kind blockers =
  blockers
  |> List.map (fun blocker -> blocker.kind)
  |> List.sort (fun left right ->
       compare (blocker_priority left) (blocker_priority right))
  |> function
  | kind :: _ -> kind
  | [] -> Rule_refuter

let format_blockers blockers =
  blockers
  |> List.fold_left
       (fun texts blocker ->
         if List.mem blocker.text texts then texts else blocker.text :: texts)
       []
  |> List.rev
  |> String.concat "; "

let unsupported ctx origin request blockers =
  let kind = primary_kind blockers in
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor:(constructor_of_kind kind)
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason:
      ("runtime truth decision refutation is not source-complete yet: "
       ^ format_blockers blockers)
    ~suggestion:
      "Emit runtimeTruthFalse only after every listed source-rule blocker has a source-derived complement/no-hit proof; do not treat failed positive search as false"
    ~source_echo:(Runtime_truth_decision_helper.reason request)
    ()

let rec premise_blockers request rule_text index prem =
  let here = rule_text ^ " " ^ premise_name index prem in
  match prem.it with
  | Il.Ast.IfPr _ ->
    [ blocker
        Deterministic_premise
        (here ^ " is IfPr; its Bool complement is not derived")
    ]
  | Il.Ast.LetPr _ ->
    [ blocker
        Deterministic_premise
        (here ^ " is LetPr; failed deterministic binding is not refuted")
    ]
  | Il.Ast.RulePr (rel_id, args, _, _) ->
    let rel_id = rel_id.it in
    if args <> [] then
      [ blocker
          Parameterized_rulepr
          (here ^ " calls relation `" ^ rel_id ^ "` with explicit RulePr arguments `"
           ^ Il.Print.string_of_args args
           ^ "`; parameterized premise refutation is not derived")
      ]
    else
      let kind =
        if String.equal rel_id request.Runtime_truth_search_helper.rel_id then
          Rule_refuter
        else
          Dependent_truth_decision
      in
      [ blocker
          kind
          (here ^ " calls dependent relation `" ^ rel_id ^ "`; dependent runtimeTruthFalse proof is not available")
      ]
  | Il.Ast.ElsePr ->
    [ blocker
        Source_construct
        (here ^ " is ElsePr; otherwise enabledness complement is not derived")
    ]
  | Il.Ast.IterPr (inner, _) ->
    blocker
      Source_construct
      (here ^ " is IterPr; iterated premise refutation is not derived")
    :: premise_blockers request rule_text index inner
  | Il.Ast.NegPr inner ->
    blocker
      Source_construct
      (here ^ " is NegPr; nested premise complement is not derived")
    :: premise_blockers request rule_text index inner

let local_rule_blockers request index rule =
  let rule_text = rule_name index rule in
  let prems =
    rule.Analysis.Function_graph.prems
    |> List.mapi (fun index prem ->
      premise_blockers request rule_text (index + 1) prem)
    |> List.concat
  in
  blocker
    Rule_refuter
    (rule_text ^ " has no source-complete head/premise refuter")
  :: prems

let closure_blockers request =
  let rel_id = request.Runtime_truth_search_helper.rel_id in
  let local =
    request.rules
    |> List.filter (fun rule ->
      String.equal rule.Analysis.Function_graph.relation_id rel_id)
  in
  let local =
    match local with
    | [] ->
      [ blocker
          Relation_local
          ("relation `" ^ rel_id ^ "` has no local RuleD clauses in the truth request")
      ]
    | rules ->
      rules
      |> List.mapi (fun index rule ->
        local_rule_blockers request (index + 1) rule)
      |> List.concat
  in
  local

let finite_domain_blockers domain =
  match Runtime_witness_domain.prepare domain with
  | Error blockers ->
    blockers
    |> List.map (fun domain_blocker ->
      blocker
        Finite_candidate_no_hit
        domain_blocker.Runtime_witness_domain.reason)
  | Ok plan ->
    [ blocker
        Finite_candidate_no_hit
        ("finite candidate sources are known ("
         ^ Runtime_witness_domain.describe_candidate_sources plan
         ^ "), but exhaustive candidate no-hit refutation is not derived")
    ]

let recursion_blockers = function
  | Runtime_truth_search_helper.Acyclic -> []
  | Runtime_truth_search_helper.Finite_transitive domain ->
    finite_domain_blockers domain
  | Runtime_truth_search_helper.Target_guided_self target ->
    [ blocker
        Target_local_no_hit
        ("target-guided self recursion through relation `"
         ^ target.Runtime_witness_proof.target_rel_id
         ^ "` and witness `"
         ^ target.Runtime_witness_proof.witness_source_id
         ^ "` has no seed/target no-hit refuter")
    ]
  | Runtime_truth_search_helper.Recursive cycle ->
    [ blocker
        Recursive_no_hit
        ("recursive dependency cycle `"
         ^ String.concat " -> " cycle
         ^ "` has no finite refutation policy")
    ]

let plan request =
  recursion_blockers request.Runtime_truth_search_helper.recursion
  @ closure_blockers request

let materialize ctx ~helper_name ~origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  match truth_request.Runtime_truth_search_helper.recursion with
  | Runtime_truth_search_helper.Acyclic ->
    Runtime_truth_no_hit_materializer.acyclic
      ctx
      ~helper_name
      ~origin
      request
    |> of_no_hit_result
  | Runtime_truth_search_helper.Finite_transitive _
  | Runtime_truth_search_helper.Target_guided_self _
  | Runtime_truth_search_helper.Recursive _ ->
    let blockers = plan truth_request in
    empty [ unsupported ctx origin request blockers ]
