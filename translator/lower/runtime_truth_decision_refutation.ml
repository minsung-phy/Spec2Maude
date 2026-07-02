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

let exp_components (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.TupE exps -> exps
  | _ -> [ exp ]

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

let string_of_prem prem =
  Il.Print.string_of_prem prem

let contains_source_premise source_premise prems =
  let source = string_of_prem source_premise in
  prems
  |> List.exists (fun prem -> String.equal source (string_of_prem prem))

let is_target_guided_source_rule target rule =
  contains_source_premise target.Runtime_witness_proof.recursive_premise rule.Analysis.Function_graph.prems
  && contains_source_premise target.Runtime_witness_proof.target_premise rule.prems

let split_source_target_input prefix_arity components =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | exp :: rest -> take (n - 1) (exp :: acc) rest
  in
  match take prefix_arity [] components with
  | Some (_prefix, [ left; right ]) -> Some (left, right)
  | Some _ | None -> None

let seed_head_key (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.CaseE (mixop, _) ->
    Some ("case:" ^ Analysis.Relation_graph.mixop_shape_text mixop)
  | Il.Ast.VarE _ -> None
  | Il.Ast.BoolE _ | Il.Ast.NumE _ | Il.Ast.TextE _
  | Il.Ast.UnE _ | Il.Ast.BinE _ | Il.Ast.CmpE _
  | Il.Ast.TupE _ | Il.Ast.ProjE _ | Il.Ast.UncaseE _
  | Il.Ast.OptE _ | Il.Ast.TheE _ | Il.Ast.StrE _
  | Il.Ast.DotE _ | Il.Ast.CompE _ | Il.Ast.ListE _
  | Il.Ast.LiftE _ | Il.Ast.MemE _ | Il.Ast.LenE _
  | Il.Ast.CatE _ | Il.Ast.IdxE _ | Il.Ast.SliceE _
  | Il.Ast.UpdE _ | Il.Ast.ExtE _ | Il.Ast.IfE _
  | Il.Ast.CallE _ | Il.Ast.IterE _ | Il.Ast.CvtE _
  | Il.Ast.SubE _ -> None

let target_guided_seed_is_functional request target =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let rel_id = truth_request.Runtime_truth_search_helper.rel_id in
  let input_count = List.length truth_request.input_terms in
  let seed_rules =
    truth_request.rules
    |> List.filter (fun rule ->
      String.equal rule.Analysis.Function_graph.relation_id rel_id
      && not (is_target_guided_source_rule target rule))
  in
  let keys =
    seed_rules
    |> List.map (fun (rule : Analysis.Function_graph.runtime_search_rule) ->
      match
        Analysis.Relation_graph.exp_components_for_count input_count rule.head
      with
      | Some components ->
        (match
           split_source_target_input target.Runtime_witness_proof.prefix_arity components
         with
        | Some (left, _witness) -> seed_head_key left
        | None -> None)
      | None -> None)
  in
  keys <> []
  && List.for_all Option.is_some keys
  &&
  let keys = List.filter_map (fun key -> key) keys in
  List.length keys = List.length (List.sort_uniq String.compare keys)

let find_witness_typ source_id components =
  components
  |> List.find_map (fun (exp : Il.Ast.exp) ->
    match exp.it with
    | Il.Ast.VarE id when String.equal id.it source_id -> Some exp.note
    | _ -> None)

let component_sort (exp : Il.Ast.exp) =
  Expr_translate.carrier_sort_of_typ exp.note

let lower_value_components ctx env origin components =
  let rec loop terms sorts guards diagnostics = function
    | [] ->
      Some (List.rev terms, List.rev sorts),
      List.rev guards,
      List.rev diagnostics
    | exp :: exps ->
      (match component_sort exp with
      | None ->
        None, List.rev guards, List.rev diagnostics
      | Some sort ->
        let lowered = Expr_translate.lower_value ctx env origin exp in
        (match lowered.term with
        | Some term ->
          loop
            (term :: terms)
            (sort :: sorts)
            (List.rev_append lowered.guards guards)
            (List.rev_append lowered.diagnostics diagnostics)
            exps
        | None ->
          None,
          List.rev_append lowered.guards guards,
          List.rev_append lowered.diagnostics diagnostics))
  in
  loop [] [] [] [] components

let local_rules request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  truth_request.Runtime_truth_search_helper.rules
  |> List.filter (fun rule ->
    String.equal
      rule.Analysis.Function_graph.relation_id
      truth_request.Runtime_truth_search_helper.rel_id)

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let acyclic_no_hit_sort helper_name =
  Maude_ir.sort ("RuntimeTruthAcyclicNoHit" ^ helper_name ^ "Conf")

let acyclic_no_hit_op helper_name =
  "runtimeTruthAcyclicNoHit" ^ helper_name

let acyclic_no_hit_ok_op helper_name =
  "runtimeTruthAcyclicNoHitOk" ^ helper_name

let acyclic_rule_refuted_sort helper_name index =
  Maude_ir.sort
    ("RuntimeTruthAcyclicRuleRefuted"
     ^ helper_name
     ^ string_of_int index
     ^ "Conf")

let acyclic_rule_refuted_op helper_name index =
  "runtimeTruthAcyclicRuleRefuted" ^ helper_name ^ string_of_int index

let acyclic_rule_refuted_ok_op helper_name index =
  "runtimeTruthAcyclicRuleRefutedOk" ^ helper_name ^ string_of_int index

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ ->
    let rec range index = function
      | [] -> []
      | _ :: sorts -> index :: range (index + 1) sorts
    in
    [ Maude_ir.Frozen (range 1 sorts) ]

let acyclic_no_hit_surface helper_name origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let result_sort = acyclic_no_hit_sort helper_name in
  let input_sorts = truth_request.Runtime_truth_search_helper.input_sorts in
  [ generated helper_name origin (Maude_ir.sort_decl result_sort)
  ; generated
      helper_name
      origin
      (Maude_ir.op
         (acyclic_no_hit_op helper_name)
         (List.map Maude_ir.sort_ref input_sorts)
         result_sort
         ~attrs:(frozen_all input_sorts))
  ; generated
      helper_name
      origin
      (Maude_ir.op (acyclic_no_hit_ok_op helper_name) [] result_sort ~attrs:[ Maude_ir.Ctor ])
  ]

let acyclic_rule_refuted_surface helper_name origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let input_sorts = truth_request.Runtime_truth_search_helper.input_sorts in
  local_rules request
  |> List.mapi (fun index _rule ->
    let index = index + 1 in
    let result_sort = acyclic_rule_refuted_sort helper_name index in
    [ generated helper_name origin (Maude_ir.sort_decl result_sort)
    ; generated
        helper_name
        origin
        (Maude_ir.op
           (acyclic_rule_refuted_op helper_name index)
           (List.map Maude_ir.sort_ref input_sorts)
           result_sort
           ~attrs:(frozen_all input_sorts))
    ; generated
        helper_name
        origin
        (Maude_ir.op
           (acyclic_rule_refuted_ok_op helper_name index)
           []
           result_sort
           ~attrs:[ Maude_ir.Ctor ])
    ])
  |> List.concat

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let lower_head_patterns ctx origin components =
  let rec loop env terms guards diagnostics = function
    | [] ->
      Some (List.rev terms), env, List.rev guards, List.rev diagnostics
    | exp :: exps ->
      let result = Expr_translate.lower_pattern_with_bindings ctx env origin exp in
      let env =
        result.introduced_bindings
        |> List.fold_left
             (fun env (id, binding) -> Expr_translate.add_var env id binding)
             env
      in
      (match result.pattern_term with
      | Some term ->
        loop
          env
          (term :: terms)
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps
      | None ->
        loop
          env
          terms
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps)
  in
  loop Expr_translate.empty_env [] [] [] components

let dependent_false_conditions ctx origin request env rel_id components =
  let lowered, guards, diagnostics =
    lower_value_components ctx env origin components
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    Error diagnostics
  else
    match lowered, Runtime_predicate_search.truth_plan ctx rel_id with
    | Some (terms, sorts), truth_plan ->
      (match
         Runtime_predicate_search.truth_helper_request
           ~input_terms:terms
           ~input_sorts:sorts
           truth_plan
       with
      | Some truth_request ->
        let truth_name =
          Helper.request
            (Context.helpers ctx)
            { Helper.kind =
                Helper.Runtime_predicate_truth_search truth_request
            ; reason = Runtime_truth_search_helper.reason truth_request
            ; origin
            }
        in
        let decision_request =
          { Runtime_truth_decision_helper.truth_helper_name = truth_name
          ; truth_request
          }
        in
        let decision_name =
          Helper.request
            (Context.helpers ctx)
            { Helper.kind =
                Helper.Runtime_predicate_truth_decision decision_request
            ; reason = Runtime_truth_decision_helper.reason decision_request
            ; origin
            }
        in
        Ok
          (List.map (fun condition -> Maude_ir.EqCondition condition) guards
           @ [ Runtime_truth_decision_helper.false_rewrite_condition
                 ~helper_name:decision_name
                 decision_request
             ])
      | None ->
        Error
          [ unsupported
              ctx
              origin
              request
              [ blocker
                  Dependent_truth_decision
                  ("dependent relation `"
                   ^ rel_id
                   ^ "` does not have a truth request for wrapper-rule refutation")
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
                "dependent RulePr components did not lower to already-bound Maude values"
            ]
        ]

let wrapper_rule_refuters ctx ~helper_name ~origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let input_count =
    List.length truth_request.Runtime_truth_search_helper.input_terms
  in
  let no_hit_op = acyclic_no_hit_op helper_name in
  let no_hit_ok = Maude_ir.Const (acyclic_no_hit_ok_op helper_name) in
  let local_rules = local_rules request in
  let aggregate_rule =
    let input_terms = truth_request.Runtime_truth_search_helper.input_terms in
    let lhs = Maude_ir.App (no_hit_op, input_terms) in
    let conditions =
      local_rules
      |> List.mapi (fun index _rule ->
        let index = index + 1 in
        Maude_ir.RewriteCond
          ( Maude_ir.App (acyclic_rule_refuted_op helper_name index, input_terms)
          , Maude_ir.Const (acyclic_rule_refuted_ok_op helper_name index) ))
    in
    generated
      helper_name
      origin
      (Maude_ir.crl
         ~label:(helper_name ^ "-acyclic-all-rules-refuted")
         lhs
         no_hit_ok
         conditions)
  in
  let lower_rule rule_index rule =
    let origin =
      child_origin
        origin
        (Printf.sprintf "RuleD[%d]" rule_index)
        "RuleD"
        rule.Analysis.Function_graph.origin.region
        rule.Analysis.Function_graph.source_echo
    in
    match
      Analysis.Relation_graph.exp_components_for_count input_count rule.head
    with
    | None ->
      Error
        [ unsupported
            ctx
            origin
            request
            [ blocker
                Rule_refuter
                ((rule_name rule_index rule)
                 ^ " head does not match the relation arity for wrapper-rule false refutation")
            ]
        ]
    | Some head_components ->
      let head_terms, env, head_guards, head_diags =
        lower_head_patterns ctx origin head_components
      in
      if List.exists Diagnostics.is_fatal head_diags then
        Error head_diags
      else
        match head_terms with
        | None ->
          Error
            (head_diags
             @ [ unsupported
                   ctx
                   origin
                   request
                   [ blocker
                       Rule_refuter
                       ((rule_name rule_index rule)
                        ^ " head pattern did not lower to a Maude term for wrapper-rule refutation")
                   ]
               ])
        | Some head_terms ->
        let lhs =
          Maude_ir.App (acyclic_rule_refuted_op helper_name rule_index, head_terms)
        in
        let rule_refuted_ok =
          Maude_ir.Const (acyclic_rule_refuted_ok_op helper_name rule_index)
        in
        let lower_prem prem_index (prem : Il.Ast.prem) =
          match prem.it with
          | Il.Ast.RulePr (rel_id, [], _mixop, exp)
            when not
                   (String.equal
                      rel_id.it
                      truth_request.Runtime_truth_search_helper.rel_id) ->
            let prem_origin =
              child_origin
                origin
                (Printf.sprintf "premise[%d]" prem_index)
                "Premise"
                prem.at
                (Some (Il.Print.string_of_prem prem))
            in
            (match
               dependent_false_conditions
                 ctx
                 prem_origin
                 request
                 env
                 rel_id.it
                 (exp_components exp)
             with
            | Ok dependent_conditions ->
              let conditions =
                List.map (fun condition -> Maude_ir.EqCondition condition) head_guards
                @ dependent_conditions
                |> Condition_closure.normalize_rule_conditions [ lhs ]
              in
              let diagnostics =
                Condition_closure.crl_admissibility_diagnostics
                  ctx
                  prem_origin
                  lhs
                  rule_refuted_ok
                  conditions
              in
              if List.exists Diagnostics.is_fatal diagnostics then
                Error diagnostics
              else
                Ok
                  (generated
                     helper_name
                     prem_origin
                     (Maude_ir.crl
                        ~label:
                          (helper_name
                           ^ "-wrapper-refuted-"
                           ^ string_of_int rule_index
                           ^ "-"
                           ^ string_of_int prem_index)
                        lhs
                        rule_refuted_ok
                        conditions))
            | Error diagnostics -> Error diagnostics)
          | _ -> Error []
        in
        let rec prems index statements diagnostics = function
          | [] ->
            if statements = [] then
              Error
                (diagnostics
                 @ [ unsupported
                       ctx
                       origin
                       request
                       [ blocker
                           Rule_refuter
                           ((rule_name rule_index rule)
                            ^ " is not a wrapper RuleD with a dependent zero-argument RulePr premise")
                       ]
                   ])
            else if List.exists Diagnostics.is_fatal diagnostics then
              Error diagnostics
            else
              Ok (List.rev statements, diagnostics)
          | prem :: rest ->
            (match lower_prem index prem with
            | Ok statement -> prems (index + 1) (statement :: statements) diagnostics rest
            | Error [] -> prems (index + 1) statements diagnostics rest
            | Error new_diagnostics ->
              prems (index + 1) statements (diagnostics @ new_diagnostics) rest)
        in
        prems 1 [] head_diags rule.prems
  in
  let rec rules index statements diagnostics = function
    | [] ->
      if statements = [] || List.exists Diagnostics.is_fatal diagnostics then
        Error diagnostics
      else
        Ok (List.rev (aggregate_rule :: statements), diagnostics)
    | rule :: rest ->
      (match lower_rule index rule with
      | Ok (new_statements, new_diagnostics) ->
        rules
          (index + 1)
          (List.rev_append new_statements statements)
          (diagnostics @ new_diagnostics)
          rest
      | Error new_diagnostics ->
        rules (index + 1) statements (diagnostics @ new_diagnostics) rest)
  in
  rules 1 [] [] local_rules

let acyclic_wrapper_refutation ctx ~helper_name ~origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  match wrapper_rule_refuters ctx ~helper_name ~origin request with
  | Ok (rules, diagnostics) ->
    let call =
      Maude_ir.App
        ( acyclic_no_hit_op helper_name
        , truth_request.Runtime_truth_search_helper.input_terms )
    in
    { statements =
        acyclic_no_hit_surface helper_name origin request @ rules
        @ acyclic_rule_refuted_surface helper_name origin request
    ; conditions =
        [ Maude_ir.RewriteCond
            (call, Maude_ir.Const (acyclic_no_hit_ok_op helper_name))
        ]
    ; diagnostics
    }
  | Error diagnostics ->
    empty
      (diagnostics
       @ [ unsupported
             ctx
             origin
             request
             [ blocker
                 Rule_refuter
                 "acyclic relation is not a wrapper-only source shape whose false branch can be delegated to dependent runtimeTruthFalse helpers"
             ]
         ])

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
      let lowered, guards, diagnostics =
        lower_value_components ctx env origin target_components
      in
      if List.exists Diagnostics.is_fatal diagnostics then
        Error diagnostics
      else
        (match lowered, Runtime_predicate_search.truth_plan ctx target_rel_id with
        | Some (target_terms, target_sorts), truth_plan ->
          (match
             Runtime_predicate_search.truth_helper_request
               ~input_terms:target_terms
               ~input_sorts:target_sorts
               truth_plan
           with
          | Some target_truth_request ->
            let target_truth_name =
              Helper.request
                (Context.helpers ctx)
                { Helper.kind =
                    Helper.Runtime_predicate_truth_search target_truth_request
                ; reason =
                    Runtime_truth_search_helper.reason target_truth_request
                ; origin
                }
            in
            let target_decision_request =
              { Runtime_truth_decision_helper.truth_helper_name =
                  target_truth_name
              ; truth_request = target_truth_request
              }
            in
            let target_decision_name =
              Helper.request
                (Context.helpers ctx)
                { Helper.kind =
                    Helper.Runtime_predicate_truth_decision
                      target_decision_request
                ; reason =
                    Runtime_truth_decision_helper.reason
                      target_decision_request
                ; origin
                }
            in
            Ok
              ( List.map (fun condition -> Maude_ir.EqCondition condition) guards
                @ [ Runtime_truth_decision_helper.false_rewrite_condition
                      ~helper_name:target_decision_name
                      target_decision_request
                  ] )
          | None ->
            Error
              [ unsupported
                  ctx
                  origin
                  request
                  [ blocker
                      Dependent_truth_decision
                      ("target-guided premise relation `"
                       ^ target_rel_id
                       ^ "` does not have a source-complete truth request for false refutation")
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
                    "target-guided target premise components did not lower to already-bound Maude values"
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
  if not (target_guided_seed_is_functional request target) then
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
  | Runtime_truth_search_helper.Target_guided_self target ->
    target_guided_refutation ctx ~origin request target
  | Runtime_truth_search_helper.Acyclic ->
    acyclic_wrapper_refutation ctx ~helper_name ~origin request
  | Runtime_truth_search_helper.Recursive _ ->
    let blockers = plan truth_request in
    empty [ unsupported ctx origin request blockers ]
