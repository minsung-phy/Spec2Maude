open Maude_ir

module Rule_components = Runtime_truth_rule_components

type result =
  { statements : Maude_ir.generated list
  ; conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  }

type no_hit_call =
  { op : string
  ; ok : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

type rule_refuter =
  { index : int
  ; op : string
  ; ok : string
  ; sort : Maude_ir.sort
  }

type no_path_call =
  { op : string
  ; ok : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let no_hit_sort helper_name =
  sort ("RuntimeTruthNoHit" ^ helper_name ^ "Conf")

let no_hit_op helper_name =
  "runtimeTruthNoHit" ^ helper_name

let no_hit_ok_op helper_name =
  "runtimeTruthNoHitOk" ^ helper_name

let no_path_sort helper_name =
  sort ("RuntimeTruthNoPath" ^ helper_name ^ "Conf")

let no_path_op helper_name =
  "runtimeTruthNoPath" ^ helper_name

let no_path_ok_op helper_name =
  "runtimeTruthNoPathOk" ^ helper_name

let all_rules_sort helper_name =
  sort ("RuntimeTruthAllRulesRefuted" ^ helper_name ^ "Conf")

let all_rules_op helper_name =
  "runtimeTruthAllRulesRefuted" ^ helper_name

let all_rules_ok_op helper_name =
  "runtimeTruthAllRulesRefutedOk" ^ helper_name

let rule_refuter_sort helper_name index =
  sort
    ("RuntimeTruthRuleRefuted"
     ^ helper_name
     ^ string_of_int index
     ^ "Conf")

let rule_refuter_op helper_name index =
  "runtimeTruthRuleRefuted" ^ helper_name ^ string_of_int index

let rule_refuter_ok_op helper_name index =
  "runtimeTruthRuleRefutedOk" ^ helper_name ^ string_of_int index

let truth_candidates_op truth_helper_name =
  "runtimeTruthCandidates" ^ truth_helper_name

let truth_candidate_op truth_helper_name =
  "runtimeTruthCandidate" ^ truth_helper_name

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ ->
    let rec range index = function
      | [] -> []
      | _ :: sorts -> index :: range (index + 1) sorts
    in
    [ Frozen (range 1 sorts) ]

let local_rules = Rule_components.local_rules

let same_source_rule
    (source_rule : Runtime_witness_proof.source_rule)
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  let same_exp left right =
    String.equal (Il.Print.string_of_exp left) (Il.Print.string_of_exp right)
  in
  let same_prem left right =
    String.equal (Il.Print.string_of_prem left) (Il.Print.string_of_prem right)
  in
  let same_prems =
    List.length source_rule.prems = List.length rule.prems
    && List.for_all2 same_prem source_rule.prems rule.prems
  in
  let same_rule_id =
    match source_rule.rule_id, rule.rule_id with
    | Some source_id, Some rule_id -> String.equal source_id rule_id
    | Some _, None | None, Some _ | None, None -> false
  in
  let same_source_echo =
    match source_rule.source_echo, rule.source_echo with
    | Some source_echo, Some rule_echo -> String.equal source_echo rule_echo
    | Some _, None | None, Some _ | None, None -> false
  in
  String.equal source_rule.relation_id rule.relation_id
  && (same_rule_id
      || same_source_echo
      || (same_exp source_rule.head rule.head && same_prems)
      || String.equal
           (Origin.source_location source_rule.origin)
           (Origin.source_location rule.origin))

let base_rules request domain =
  let transitive = domain.Runtime_witness_proof.transitive in
  local_rules request
  |> List.filter (fun rule -> not (same_source_rule transitive.rule rule))

let rule_refuter helper_name index =
  { index
  ; op = rule_refuter_op helper_name index
  ; ok = rule_refuter_ok_op helper_name index
  ; sort = rule_refuter_sort helper_name index
  }

let spectec_terminals =
  sort "SpectecTerminals"

let input_var_name helper_name index =
  "RTNHIN" ^ helper_name ^ string_of_int (index + 1)

let candidates_var_name helper_name =
  "RTNHCANDS" ^ helper_name

let rest_var_name helper_name =
  "RTNHREST" ^ helper_name

let witness_var_name helper_name source_id =
  Naming.maude_var (helper_name ^ "-no-hit-witness-" ^ source_id)

let input_vars request helper_name =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  truth_request.input_sorts
  |> List.mapi (fun index _ -> Var (input_var_name helper_name index))

let no_hit_call ~helper_name request : no_hit_call =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let op = no_hit_op helper_name in
  let ok = no_hit_ok_op helper_name in
  { op
  ; ok
  ; lhs = App (op, truth_request.input_terms)
  ; rhs = Const ok
  }

let no_path_call ~helper_name _request input_terms candidates : no_path_call =
  let op = no_path_op helper_name in
  let ok = no_path_ok_op helper_name in
  { op
  ; ok
  ; lhs = App (op, input_terms @ [ candidates ])
  ; rhs = Const ok
  }

let all_rules_call ~helper_name input_terms =
  App (all_rules_op helper_name, input_terms)

let all_rules_ok helper_name =
  Const (all_rules_ok_op helper_name)

let rule_refuter_call (refuter : rule_refuter) input_terms =
  App (refuter.op, input_terms)

let rule_refuter_ok (refuter : rule_refuter) =
  Const refuter.ok

let all_rules_surface helper_name origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let result_sort = all_rules_sort helper_name in
  let op_name = all_rules_op helper_name in
  let ok_name = all_rules_ok_op helper_name in
  [ generated helper_name origin (sort_decl result_sort)
  ; generated
      helper_name
      origin
      (op
         op_name
         (List.map sort_ref truth_request.input_sorts)
         result_sort
         ~attrs:(frozen_all truth_request.input_sorts))
  ; generated helper_name origin (op ok_name [] result_sort ~attrs:[ Ctor ])
  ]

let no_path_surface helper_name origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let result_sort = no_path_sort helper_name in
  let op_name = no_path_op helper_name in
  let ok_name = no_path_ok_op helper_name in
  [ generated helper_name origin (sort_decl result_sort)
  ; generated
      helper_name
      origin
      (op
         op_name
         (List.map sort_ref truth_request.input_sorts @ [ sort_ref spectec_terminals ])
         result_sort
         ~attrs:
           (frozen_all (truth_request.input_sorts @ [ spectec_terminals ])))
  ; generated helper_name origin (op ok_name [] result_sort ~attrs:[ Ctor ])
  ]

let rule_refuter_surface helper_name origin request rules =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  rules
  |> List.mapi (fun index _rule ->
    let refuter = rule_refuter helper_name (index + 1) in
    [ generated helper_name origin (sort_decl refuter.sort)
    ; generated
        helper_name
        origin
        (op
           refuter.op
           (List.map sort_ref truth_request.input_sorts)
           refuter.sort
           ~attrs:(frozen_all truth_request.input_sorts))
    ; generated
        helper_name
        origin
        (op refuter.ok [] refuter.sort ~attrs:[ Ctor ])
    ])
  |> List.concat

let helper_surface helper_name origin request rules =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let result_sort = no_hit_sort helper_name in
  let call = no_hit_call ~helper_name request in
  [ generated helper_name origin (sort_decl result_sort)
  ; generated
      helper_name
      origin
      (op
         call.op
         (List.map sort_ref truth_request.input_sorts)
         result_sort
         ~attrs:(frozen_all truth_request.input_sorts))
  ; generated helper_name origin (op call.ok [] result_sort ~attrs:[ Ctor ])
  ]
  @ no_path_surface helper_name origin request
  @ all_rules_surface helper_name origin request
  @ rule_refuter_surface helper_name origin request rules

let local_rule_names rules =
  rules
  |> List.mapi (fun index rule ->
    match rule.Analysis.Function_graph.rule_id with
    | Some rule_id -> "`" ^ rule_id ^ "`"
    | None -> "RuleD[" ^ string_of_int (index + 1) ^ "]")

let generated_input_vars helper_name origin request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  truth_request.input_sorts
  |> List.mapi (fun index sort ->
    generated
      helper_name
      origin
      (var (input_var_name helper_name index) (sort_ref sort)))

let no_path_vars helper_name origin witness_source_id =
  [ generated
      helper_name
      origin
      (var (candidates_var_name helper_name) (sort_ref spectec_terminals))
  ; generated
      helper_name
      origin
      (var (rest_var_name helper_name) (sort_ref spectec_terminals))
  ; generated
      helper_name
      origin
      (var
         (witness_var_name helper_name witness_source_id)
         (sort_ref (sort "SpectecTerminal")))
  ]

let rec is_closed_pattern = function
  | Var _ -> false
  | Const _ | Qid _ -> true
  | App (_constructor, args) -> List.for_all is_closed_pattern args

let expected_from_pattern subject = function
  | Var _ -> Some subject
  | Const _ as term -> Some term
  | Qid _ as term -> Some term
  | App (_constructor, _args) as term when is_closed_pattern term -> Some term
  | App _ -> None

let head_mismatch_conditions input_terms pattern_terms =
  let rec loop seen acc = function
    | [], [] -> List.rev acc
    | subject :: subjects, Var name :: patterns ->
      (match List.assoc_opt name seen with
      | Some previous ->
        loop
          seen
          (BoolCond (App ("_=/=_", [ subject; previous ])) :: acc)
          (subjects, patterns)
      | None -> loop ((name, subject) :: seen) acc (subjects, patterns))
    | subject :: subjects, pattern :: patterns ->
      (match expected_from_pattern subject pattern with
      | Some expected ->
        loop
          seen
          (BoolCond (App ("_=/=_", [ subject; expected ])) :: acc)
          (subjects, patterns)
      | None -> loop seen acc (subjects, patterns))
    | _ -> List.rev acc
  in
  loop [] [] (input_terms, pattern_terms)

let negate_eq_condition = function
  | BoolCond term -> Some (EqCond (term, Const "false"))
  | EqCond (left, right) -> Some (BoolCond (App ("_=/=_", [ left; right ])))
  | MatchCond _ | MembershipCond _ -> None

let rule_refuter_statement helper_name origin refuter lhs conditions =
  match conditions with
  | [] -> None
  | _ ->
    Some
      (generated
         helper_name
         origin
         (crl
            ~label:(helper_name ^ "-rule-refuted-" ^ string_of_int refuter.index)
            lhs
            (rule_refuter_ok refuter)
            (List.map (fun condition -> EqCondition condition) conditions)))

let head_mismatch_rules helper_name origin refuter input_terms pattern_terms =
  head_mismatch_conditions input_terms pattern_terms
  |> List.filter_map (fun condition ->
    rule_refuter_statement
      helper_name
      origin
      refuter
      (rule_refuter_call refuter input_terms)
      [ condition ])

let head_guard_refuter_rules helper_name origin refuter lhs guards =
  guards
  |> List.filter_map negate_eq_condition
  |> List.filter_map (fun condition ->
    rule_refuter_statement helper_name origin refuter lhs [ condition ])

let same_relation_no_hit_condition helper_name request terms =
  let call = no_hit_call ~helper_name request in
  RewriteCond (App (call.op, terms), call.rhs)

let premise_refuter_rules
    ctx
    helper_name
    origin
    request
    refuter
    env
    lhs
    prem_index
    (prem : Il.Ast.prem)
  =
  let prem_origin =
    Rule_components.child_origin
      origin
      (Printf.sprintf "premise[%d]" prem_index)
      "Premise"
      prem.at
      (Some (Il.Print.string_of_prem prem))
  in
  match prem.it with
  | Il.Ast.IfPr exp ->
    let lowered = Expr_translate.lower_bool_condition ctx env prem_origin exp in
    (match lowered.term with
    | Some term ->
      [ generated
          helper_name
          prem_origin
          (crl
             ~label:
               (helper_name
                ^ "-rule-refuted-"
                ^ string_of_int refuter.index
                ^ "-if-"
                ^ string_of_int prem_index)
             lhs
             (rule_refuter_ok refuter)
             (List.map
                (fun condition -> EqCondition condition)
                lowered.guards
              @ [ EqCondition (EqCond (term, Const "false")) ]))
      ],
      lowered.diagnostics
    | None -> [], lowered.diagnostics)
  | Il.Ast.RulePr (rel_id, [], _mixop, exp) ->
    let components = Rule_components.exp_components exp in
    let lowered =
      Rule_components.lower_value_components ctx env prem_origin components
    in
    if List.exists Diagnostics.is_fatal lowered.diagnostics then
      [], lowered.diagnostics
    else
      (match lowered.values with
      | Some (terms, _sorts)
        when String.equal
               rel_id.it
               request.Runtime_truth_decision_helper.truth_request.rel_id ->
        [ generated
            helper_name
            prem_origin
            (crl
               ~label:
                 (helper_name
                  ^ "-rule-refuted-"
                  ^ string_of_int refuter.index
                  ^ "-recursive-"
                  ^ string_of_int prem_index)
               lhs
               (rule_refuter_ok refuter)
               (List.map (fun condition -> EqCondition condition) lowered.guards
                @ [ same_relation_no_hit_condition helper_name request terms ]))
        ],
        lowered.diagnostics
      | Some _ ->
        (* A dependent predicate can refute this premise only when the
           dependent relation already has a source-complete false helper.
           Requesting it speculatively here leaks helper diagnostics for
           unrelated closures and can make an incomplete refuter look like
           several separate fatal failures. Keep the local no-hit helper
           conservative until dependent false proofs are available. *)
        [], lowered.diagnostics
      | None -> [], lowered.diagnostics)
  | Il.Ast.RulePr (_, _ :: _, _, _)
  | Il.Ast.LetPr _ | Il.Ast.ElsePr | Il.Ast.IterPr _ | Il.Ast.NegPr _ ->
    [], []

let rule_refuter_rules ctx helper_name origin request rules =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let input_count = List.length truth_request.input_terms in
  let input_terms = input_vars request helper_name in
  let lower_rule index rule =
    let refuter = rule_refuter helper_name index in
    let origin =
      Rule_components.child_origin
        origin
        (Printf.sprintf "RuleD[%d]" index)
        "RuleD"
        rule.Analysis.Function_graph.origin.region
        rule.Analysis.Function_graph.source_echo
    in
    match
      Analysis.Relation_graph.exp_components_for_count input_count rule.head
    with
    | None -> [], []
    | Some components ->
      let lowered_head =
        Rule_components.lower_complete_head_patterns ctx origin components
      in
      (match lowered_head.terms with
      | None -> [], lowered_head.diagnostics
      | Some pattern_terms ->
        let lhs = rule_refuter_call refuter pattern_terms in
        let head_rules =
          head_mismatch_rules helper_name origin refuter input_terms pattern_terms
          @ head_guard_refuter_rules
              helper_name
              origin
              refuter
              lhs
              lowered_head.guards
        in
        let premise_rules, premise_diags =
          rule.Analysis.Function_graph.prems
          |> List.mapi (fun prem_index prem ->
            premise_refuter_rules
              ctx
              helper_name
              origin
              request
              refuter
              lowered_head.env
              lhs
              (prem_index + 1)
              prem)
          |> List.fold_left
               (fun (rules, diagnostics) (new_rules, new_diagnostics) ->
                 List.rev_append new_rules rules,
                 List.rev_append new_diagnostics diagnostics)
               ([], [])
        in
        List.rev_append premise_rules head_rules,
        lowered_head.diagnostics @ List.rev premise_diags)
  in
  rules
  |> List.mapi (fun index rule -> lower_rule (index + 1) rule)
  |> List.fold_left
       (fun (rules, diagnostics) (new_rules, new_diagnostics) ->
         List.rev_append new_rules rules,
         List.rev_append new_diagnostics diagnostics)
       ([], [])
  |> fun (rules, diagnostics) -> List.rev rules, List.rev diagnostics

let all_rules_rule helper_name origin request rules =
  let input_terms = input_vars request helper_name in
  let conditions =
    rules
    |> List.mapi (fun index _rule ->
      let refuter = rule_refuter helper_name (index + 1) in
      RewriteCond (rule_refuter_call refuter input_terms, rule_refuter_ok refuter))
  in
  match conditions with
  | [] -> []
  | _ ->
    [ generated
        helper_name
        origin
        (crl
           ~label:(helper_name ^ "-all-rules-refuted")
           (all_rules_call ~helper_name input_terms)
           (all_rules_ok helper_name)
           conditions)
    ]

let no_path_empty_rule helper_name origin request =
  let input_terms = input_vars request helper_name in
  let call = no_path_call ~helper_name request input_terms (Const "eps") in
  [ generated
      helper_name
      origin
      (crl
         ~label:(helper_name ^ "-no-path-empty")
         call.lhs
         call.rhs
         [ RewriteCond
             (all_rules_call ~helper_name input_terms, all_rules_ok helper_name)
         ])
  ]

let split_transitive_terms prefix_arity terms =
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

let no_path_step_rules helper_name origin request domain =
  let transitive = domain.Runtime_witness_proof.transitive in
  let input_terms = input_vars request helper_name in
  match split_transitive_terms transitive.prefix_arity input_terms with
  | None -> []
  | Some (prefix, left, right) ->
    let rest = Var (rest_var_name helper_name) in
    let witness =
      Var (witness_var_name helper_name transitive.witness_source_id)
    in
    let truth_helper_name =
      request.Runtime_truth_decision_helper.truth_helper_name
    in
    let candidate =
      App (truth_candidate_op truth_helper_name, [ witness ])
    in
    let candidates = App ("_ _", [ candidate; rest ]) in
    let current = no_path_call ~helper_name request input_terms candidates in
    let without_current = no_path_call ~helper_name request input_terms rest in
    let left_terms = prefix @ [ left; witness ] in
    let right_terms = prefix @ [ witness; right ] in
    let without_left = no_path_call ~helper_name request left_terms rest in
    let without_right = no_path_call ~helper_name request right_terms rest in
    [ generated
        helper_name
        origin
        (crl
           ~label:(helper_name ^ "-no-path-step-left")
           current.lhs
           current.rhs
           [ RewriteCond (without_current.lhs, without_current.rhs)
           ; RewriteCond (without_left.lhs, without_left.rhs)
           ])
    ; generated
        helper_name
        origin
        (crl
           ~label:(helper_name ^ "-no-path-step-right")
           current.lhs
           current.rhs
           [ RewriteCond (without_current.lhs, without_current.rhs)
           ; RewriteCond (without_right.lhs, without_right.rhs)
           ])
    ]

let no_hit_entry_rule helper_name origin request =
  let input_terms = input_vars request helper_name in
  let candidates = Var (candidates_var_name helper_name) in
  let no_hit = no_hit_call ~helper_name request in
  let no_path = no_path_call ~helper_name request input_terms candidates in
  let truth_helper_name =
    request.Runtime_truth_decision_helper.truth_helper_name
  in
  [ generated
      helper_name
      origin
      (crl
         ~label:(helper_name ^ "-no-hit-entry")
         (App (no_hit.op, input_terms))
         no_hit.rhs
         [ EqCondition
             (MatchCond
                ( candidates
                , App (truth_candidates_op truth_helper_name, input_terms) ))
         ; RewriteCond (no_path.lhs, no_path.rhs)
         ])
  ]

let no_hit_rules ctx helper_name origin request domain =
  let rules = base_rules request domain in
  let refuter_rules, refuter_diagnostics =
    rule_refuter_rules ctx helper_name origin request rules
  in
  ( generated_input_vars helper_name origin request
    @ no_path_vars
        helper_name
        origin
        domain.Runtime_witness_proof.transitive.witness_source_id
    @ all_rules_rule helper_name origin request rules
    @ refuter_rules
    @ no_path_empty_rule helper_name origin request
    @ no_path_step_rules helper_name origin request domain
    @ no_hit_entry_rule helper_name origin request
  , refuter_diagnostics )

let finite_domain_reason domain =
  match Runtime_witness_domain.prepare domain with
  | Error blockers ->
    blockers
    |> List.map (fun blocker -> blocker.Runtime_witness_domain.reason)
    |> String.concat "; "
  | Ok plan ->
    "finite candidate sources are known ("
    ^ Runtime_witness_domain.describe_candidate_sources plan
    ^ ")"

let unsupported ctx origin request domain =
  let rules = base_rules request domain |> local_rule_names in
  let rules =
    match rules with
    | [] -> "no local RuleD"
    | _ -> String.concat ", " rules
  in
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor:"RuntimeTruthNoHit/materializer/finite-transitive/refuter-unimplemented"
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason:
      ("finite-transitive runtime truth no-hit needs source-complete per-RuleD refuters before it can emit runtimeTruthFalse; "
       ^ finite_domain_reason domain
       ^ "; local rules to refute: "
       ^ rules)
    ~suggestion:
      "Implement relation-local RuleD no-hit helpers first, then connect dependent runtimeTruthFalse obligations and the finite candidate loop; do not encode failed positive search as false"
    ~source_echo:(Runtime_truth_decision_helper.reason request)
    ()

let finite_transitive ctx ~helper_name ~origin request domain =
  let call = no_hit_call ~helper_name request in
  let rules = base_rules request domain in
  let no_hit_statements, no_hit_diagnostics =
    no_hit_rules ctx helper_name origin request domain
  in
  let diagnostics = no_hit_diagnostics @ [ unsupported ctx origin request domain ] in
  if List.exists Diagnostics.is_fatal diagnostics then
    { statements = []; conditions = []; diagnostics }
  else
    { statements =
        helper_surface helper_name origin request rules
        @ no_hit_statements
    ; conditions = [ RewriteCond (call.lhs, call.rhs) ]
    ; diagnostics
    }
