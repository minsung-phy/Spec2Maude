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

module Rule_components = Runtime_truth_rule_components

let empty diagnostics =
  { statements = []; conditions = []; diagnostics }

let of_no_hit_result (result : Runtime_truth_no_hit_materializer.result) =
  { statements = result.statements
  ; conditions = result.conditions
  ; diagnostics = result.diagnostics
  }

let seed_search_op helper_name =
  "runtimeTruthSeedSearch" ^ helper_name

let seed_hit_op helper_name =
  "runtimeTruthSeedHit" ^ helper_name

let witness_var helper_name source_id =
  Maude_ir.Var (Naming.maude_var (helper_name ^ "-witness-" ^ source_id))

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
    ~enclosing:(Context.enclosing_path ctx)
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

let split_target_input prefix_arity terms =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | term :: rest -> take (n - 1) (term :: acc) rest
  in
  match take prefix_arity [] terms with
  | Some (prefix, [ left; right ]) -> Some (prefix, left, right)
  | Some _ | None -> None

let exp_components = Rule_components.exp_components

let bind_direct_component env (exp : Il.Ast.exp) term sort =
  match exp.it with
  | Il.Ast.VarE id ->
    Some
      (Expr_translate.add_var
         env
         id.it
         { Expr_translate.term; sort; typ = exp.note })
  | _ -> None

let env_for_head_components components terms sorts =
  let rec loop env = function
    | [], [], [] -> Some env
    | component :: components, term :: terms, sort :: sorts ->
      (match bind_direct_component env component term sort with
      | Some env -> loop env (components, terms, sorts)
      | None -> None)
    | _ -> None
  in
  loop Expr_translate.empty_env (components, terms, sorts)

let add_witness_binding env source_id typ witness =
  Expr_translate.add_var
    env
    source_id
    { Expr_translate.term = witness
    ; sort = Maude_ir.sort "SpectecTerminal"
    ; typ
    }

let target_premise_components target =
  match target.Runtime_witness_proof.target_premise.it with
  | Il.Ast.RulePr (rel_id, [], _mixop, exp) ->
    Some (rel_id.it, exp_components exp)
  | Il.Ast.RulePr (_, _ :: _, _, _)
  | Il.Ast.IfPr _ | Il.Ast.LetPr _ | Il.Ast.ElsePr
  | Il.Ast.IterPr _ | Il.Ast.NegPr _ -> None

let find_witness_typ source_id components =
  components
  |> List.find_map (fun (exp : Il.Ast.exp) ->
    match exp.it with
    | Il.Ast.VarE id when String.equal id.it source_id -> Some exp.note
    | _ -> None)

let target_truth_decision
    ctx
    origin
    request
    target
    witness
  =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  match
    split_target_input
      target.Runtime_witness_proof.prefix_arity
      truth_request.Runtime_truth_search_helper.input_terms,
    Analysis.Relation_graph.exp_components_for_count
      (List.length truth_request.Runtime_truth_search_helper.input_terms)
      target.Runtime_witness_proof.rule.head,
    target_premise_components target
  with
  | Some (_prefix_terms, _left, _right), Some head_components, Some (target_rel_id, target_components) ->
    (match
       env_for_head_components
         head_components
         truth_request.Runtime_truth_search_helper.input_terms
         truth_request.Runtime_truth_search_helper.input_sorts,
       find_witness_typ
         target.Runtime_witness_proof.witness_source_id
         target_components
     with
    | Some env, Some witness_typ ->
      let env =
        add_witness_binding
          env
          target.Runtime_witness_proof.witness_source_id
          witness_typ
          witness
      in
      (match
         Runtime_truth_dependent_false.lower
           ctx
           origin
           env
           ~rel_id:target_rel_id
           ~components:target_components
       with
      | Ok conditions -> Ok conditions
      | Error (Runtime_truth_dependent_false.Diagnostics diagnostics) ->
        Error diagnostics
      | Error (Runtime_truth_dependent_false.Blocked blockers) ->
        Error
          [ unsupported
              ctx
              origin
              request
              [ blocker
                  Dependent_truth_decision
                  ("target-guided target premise has no source-complete false decision: "
                   ^ String.concat "; " blockers)
              ]
          ])
    | None, _ ->
      Error
        [ unsupported
            ctx
            origin
            request
            [ blocker
                Dependent_truth_decision
                "target-guided source head has non-direct components, so false refutation cannot bind call inputs source-isomorphically yet"
            ]
        ]
    | _, None ->
      Error
        [ unsupported
            ctx
            origin
            request
            [ blocker
                Dependent_truth_decision
                ("target-guided witness `"
                 ^ target.Runtime_witness_proof.witness_source_id
                 ^ "` is not a direct variable in the target premise")
            ]
        ])
  | _ ->
    Error
      [ unsupported
          ctx
          origin
          request
          [ blocker
              Dependent_truth_decision
              "target-guided false refutation could not recover prefix/left/right and target premise components from the proven IL shape"
          ]
      ]

let target_guided_refutation ctx ~origin request target =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  if
    not
      (Runtime_truth_decision_false_support.target_guided_seed_is_functional
         request
         target)
  then
    empty
      [ unsupported
          ctx
          origin
          request
          [ blocker
              Target_local_no_hit
              "target-guided false refutation needs either a source-complete seed no-hit helper or a structural proof that seed search is functional; neither proof is available for this IL shape"
          ]
      ]
  else
    match
      split_target_input
        target.Runtime_witness_proof.prefix_arity
        truth_request.Runtime_truth_search_helper.input_terms
    with
  | None ->
    empty
      [ unsupported
          ctx
          origin
          request
          [ blocker
              Target_local_no_hit
              "target-guided truth request input terms are not prefix plus left endpoint plus target endpoint"
          ]
      ]
  | Some (prefix, left, _right) ->
    let witness =
      witness_var
        request.Runtime_truth_decision_helper.truth_helper_name
        target.Runtime_witness_proof.witness_source_id
    in
    let seed_condition =
      Maude_ir.RewriteCond
        ( Maude_ir.App
            ( seed_search_op request.truth_helper_name
            , prefix @ [ left ] )
        , Maude_ir.App
            ( seed_hit_op request.truth_helper_name
            , [ witness ] ) )
    in
    match target_truth_decision ctx origin request target witness with
    | Ok target_conditions ->
      { statements = []
      ; conditions = seed_condition :: target_conditions
      ; diagnostics = []
      }
    | Error diagnostics -> empty diagnostics

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
  | Runtime_truth_search_helper.Finite_transitive domain ->
    Runtime_truth_no_hit_materializer.finite_transitive
      ctx
      ~helper_name
      ~origin
      request
      domain
    |> of_no_hit_result
  | Runtime_truth_search_helper.Acyclic ->
    Runtime_truth_no_hit_materializer.acyclic
      ctx
      ~helper_name
      ~origin
      request
    |> of_no_hit_result
  | Runtime_truth_search_helper.Target_guided_self target ->
    target_guided_refutation ctx ~origin request target
  | Runtime_truth_search_helper.Recursive _ ->
    let blockers = plan truth_request in
    empty [ unsupported ctx origin request blockers ]
