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

type refuter_rules =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  ; complete : bool
  ; blockers : string list
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

let spectec_terminal =
  sort "SpectecTerminal"

let input_var_name helper_name index =
  "RTNHIN" ^ helper_name ^ string_of_int (index + 1)

let candidates_var_name helper_name =
  "RTNHCANDS" ^ helper_name

let full_candidates_var_name helper_name =
  "RTNHFULL" ^ helper_name

let rest_var_name helper_name =
  "RTNHREST" ^ helper_name

let visited_var_name helper_name =
  "RTNHVIS" ^ helper_name

let witness_var_name helper_name source_id =
  Naming.maude_var (helper_name ^ "-no-hit-witness-" ^ source_id)

let visited_key_op helper_name =
  "runtimeTruthNoHitVisitedKey" ^ helper_name

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

let no_path_call
    ~helper_name _request input_terms full_candidates candidates visited
    : no_path_call
  =
  let op = no_path_op helper_name in
  let ok = no_path_ok_op helper_name in
  { op
  ; ok
  ; lhs = App (op, input_terms @ [ full_candidates; candidates; visited ])
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

let complete statements diagnostics =
  { statements; diagnostics; complete = true; blockers = [] }

let incomplete ?(diagnostics = []) reason =
  { statements = []
  ; diagnostics
  ; complete = false
  ; blockers = [ reason ]
  }

let append_refuters left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  ; complete = left.complete && right.complete
  ; blockers = left.blockers @ right.blockers
  }

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
         (List.map sort_ref truth_request.input_sorts
          @ [ sort_ref spectec_terminals
            ; sort_ref spectec_terminals
            ; sort_ref spectec_terminals
            ])
         result_sort
         ~attrs:
           (frozen_all
              (truth_request.input_sorts
               @ [ spectec_terminals; spectec_terminals; spectec_terminals ])))
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

let no_hit_surface helper_name origin request =
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

let helper_surface helper_name origin request rules =
  no_hit_surface helper_name origin request
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
      (var (full_candidates_var_name helper_name) (sort_ref spectec_terminals))
  ; generated
      helper_name
      origin
      (var (rest_var_name helper_name) (sort_ref spectec_terminals))
  ; generated
      helper_name
      origin
      (var (visited_var_name helper_name) (sort_ref spectec_terminals))
  ; generated
      helper_name
      origin
      (var
         (witness_var_name helper_name witness_source_id)
         (sort_ref (sort "SpectecTerminal")))
  ; generated
      helper_name
      origin
      (op
         (visited_key_op helper_name)
         [ sort_ref (sort "SpectecTerminal")
         ; sort_ref (sort "SpectecTerminal")
         ; sort_ref (sort "SpectecTerminal")
         ]
         spectec_terminal
         ~attrs:[ Ctor ])
  ]

let rec is_closed_pattern = function
  | Var _ -> false
  | Const _ | Qid _ -> true
  | App (_constructor, args) -> List.for_all is_closed_pattern args

let rec nth_opt items index =
  match items, index with
  | item :: _, 0 -> Some item
  | _ :: rest, index when index > 0 -> nth_opt rest (index - 1)
  | _ -> None

let option_all items =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Some item :: rest -> loop (item :: acc) rest
    | None :: _ -> None
  in
  loop [] items

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

let append_prefix_conditions prefix conditions =
  prefix @ conditions

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

let rulepr_components ctx rel_id exp =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id with
  | None -> Rule_components.exp_components exp
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let expected_count = List.length relation_shape.Relation_shape.components in
    (match Analysis.Relation_graph.exp_components_for_count expected_count exp with
    | Some components -> components
    | None -> Rule_components.exp_components exp)

let typ_is_iter = Type_shape.typ_is_iter

let source_preserving_iter_source (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.IterE
      ( { it = Il.Ast.VarE body_id; _ }
      , (Il.Ast.List, [ generator_id, source_exp ]) )
    when String.equal body_id.it generator_id.it ->
    source_exp
  | _ -> exp

let flat_list_element_typ (typ : Il.Ast.typ) =
  match typ.it with
  | Il.Ast.IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let rec indexed_source (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.SubE (inner, source_typ, _) ->
    (match indexed_source inner with
    | Some (index_id, source_exp, None) ->
      Some (index_id, source_exp, Some source_typ)
    | indexed -> indexed)
  | Il.Ast.CvtE (inner, _, _) ->
    indexed_source inner
  | Il.Ast.IdxE (source_exp, index_exp) ->
    (match index_exp.it with
    | Il.Ast.VarE index_id -> Some (index_id.it, source_exp, None)
    | _ -> None)
  | _ -> None

let indexed_false_sort helper_name refuter_index prem_index =
  sort
    ("RuntimeTruthAllIndexedFalse"
     ^ helper_name
     ^ string_of_int refuter_index
     ^ "x"
     ^ string_of_int prem_index
     ^ "Conf")

let indexed_false_op helper_name refuter_index prem_index =
  "runtimeTruthAllIndexedFalse"
  ^ helper_name
  ^ string_of_int refuter_index
  ^ "x"
  ^ string_of_int prem_index

let indexed_false_ok_op helper_name refuter_index prem_index =
  "runtimeTruthAllIndexedFalseOk"
  ^ helper_name
  ^ string_of_int refuter_index
  ^ "x"
  ^ string_of_int prem_index

let indexed_head_no_match_sort helper_name refuter_index =
  sort
    ("RuntimeTruthIndexedHeadNoMatch"
     ^ helper_name
     ^ string_of_int refuter_index
     ^ "Conf")

let indexed_head_no_match_op helper_name refuter_index =
  "runtimeTruthIndexedHeadNoMatch"
  ^ helper_name
  ^ string_of_int refuter_index

let indexed_head_no_match_ok_op helper_name refuter_index =
  "runtimeTruthIndexedHeadNoMatchOk"
  ^ helper_name
  ^ string_of_int refuter_index

let indexed_head_var helper_name refuter_index prem_index =
  "RTIDXHEAD" ^ helper_name ^ string_of_int refuter_index ^ "x" ^ string_of_int prem_index

let indexed_tail_var helper_name refuter_index prem_index =
  "RTIDXTAIL" ^ helper_name ^ string_of_int refuter_index ^ "x" ^ string_of_int prem_index

let indexed_head_target_var helper_name refuter_index =
  "RTIDXHTARGET" ^ helper_name ^ string_of_int refuter_index

let indexed_head_list_head_var helper_name refuter_index =
  "RTIDXHHEAD" ^ helper_name ^ string_of_int refuter_index

let indexed_head_list_tail_var helper_name refuter_index =
  "RTIDXHTAIL" ^ helper_name ^ string_of_int refuter_index

let indexed_capture_var helper_name refuter_index prem_index index =
  "RTIDXC"
  ^ helper_name
  ^ string_of_int refuter_index
  ^ "x"
  ^ string_of_int prem_index
  ^ "x"
  ^ string_of_int index

let indexed_false_call op source captures =
  App (op, source :: captures)

let indexed_head_no_match_call op target source =
  App (op, [ target; source ])

let typecheck_for_indexed_element_typ ctx env origin typ target target_sort =
  let witness =
    Expr_translate.lower_type_witness
      ctx
      env
      origin
      ~constructor:"RuntimeTruthNoHit/indexed-dependent-element"
      typ
  in
  match witness.term with
  | None -> [], witness.diagnostics
  | Some witness_term ->
    ( witness.guards
      @ Expr_translate.typecheck_conditions_for_typ
          typ
          target_sort
          target
          witness_term
    , witness.diagnostics )

let indexed_dependent_false
    ctx
    helper_name
    origin
    _request
    refuter
    env
    prefix_conditions
    lhs
    rhs
    prem_index
    (rel_id : Il.Ast.id)
    (components : Il.Ast.exp list)
  =
  let indexed =
    components
    |> List.mapi (fun index component -> index, indexed_source component)
    |> List.filter_map (function
      | index, Some (_index_source_id, source_exp, source_element_typ) ->
        Some (index, source_exp, source_element_typ)
      | _index, None -> None)
  in
  match indexed with
  | [ indexed_index, source_exp, source_element_typ ] ->
    let source_exp = source_preserving_iter_source source_exp in
    let source_element_typ =
      match source_element_typ with
      | Some typ -> Some typ
      | None -> flat_list_element_typ source_exp.note
    in
    (match source_element_typ with
    | None -> None
    | Some source_element_typ ->
      (match Expr_translate.carrier_sort_of_typ source_element_typ with
      | None -> None
      | Some source_element_sort ->
        let source_result =
          Expr_translate.lower_sequence ctx env origin source_exp
        in
        (match source_result.term with
        | None -> None
        | Some source_term ->
          let capture_results =
            components
            |> List.mapi (fun index (component : Il.Ast.exp) ->
              if index = indexed_index then Some None
              else
                let lowered = Expr_translate.lower_value ctx env origin component in
                match lowered.term, Expr_translate.carrier_sort_of_typ component.note with
                | Some term, Some sort ->
                  Some
                    (Some
                       (index, term, sort, lowered.guards, lowered.diagnostics))
                | _ -> None)
          in
          if List.exists Option.is_none capture_results then
            None
          else
            let captures =
              capture_results
              |> List.filter_map (function
                | Some (Some capture) -> Some capture
                | Some None | None -> None)
            in
            let capture_terms =
              captures |> List.map (fun (_index, term, _sort, _guards, _diags) -> term)
            in
            let capture_sorts =
              captures |> List.map (fun (_index, _term, sort, _guards, _diags) -> sort)
            in
            let capture_guards =
              captures
              |> List.concat_map (fun (_index, _term, _sort, guards, _diags) -> guards)
            in
            let capture_diags =
              captures
              |> List.concat_map (fun (_index, _term, _sort, _guards, diags) -> diags)
            in
            let head_var =
              indexed_head_var helper_name refuter.index prem_index
            in
            let tail_var =
              indexed_tail_var helper_name refuter.index prem_index
            in
            let head = Var head_var in
            let tail = Var tail_var in
            let formal_captures =
              capture_sorts
              |> List.mapi (fun index _sort ->
                Var (indexed_capture_var helper_name refuter.index prem_index index))
            in
            let input_terms =
              components
              |> List.mapi (fun index _component ->
                if index = indexed_index then
                  Some head
                else
                  let formal_index =
                    List.length
                      (components
                       |> List.filteri (fun earlier _ ->
                         earlier < index && earlier <> indexed_index))
                  in
                  nth_opt formal_captures formal_index)
            in
            let input_sorts =
              components
              |> List.mapi (fun index _component ->
                if index = indexed_index then
                  Some source_element_sort
                else
                  let formal_index =
                    List.length
                      (components
                       |> List.filteri (fun earlier _ ->
                         earlier < index && earlier <> indexed_index))
                  in
                  nth_opt capture_sorts formal_index)
            in
            (match option_all input_terms, option_all input_sorts with
            | Some input_terms, Some input_sorts ->
              let truth_plan =
                Runtime_predicate_search.truth_plan ctx rel_id.it
              in
              (match
                 Runtime_predicate_search.truth_helper_request
                   ~input_terms
                   ~input_sorts
                   truth_plan
               with
            | None -> None
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
                    ; reason =
                        Runtime_truth_decision_helper.reason decision_request
                    ; origin
                    }
                in
                let op_name =
                  indexed_false_op helper_name refuter.index prem_index
                in
                let ok_name =
                  indexed_false_ok_op helper_name refuter.index prem_index
                in
                let result_sort =
                  indexed_false_sort helper_name refuter.index prem_index
                in
                let call source captures =
                  indexed_false_call op_name source captures
                in
                let empty_lhs = call (Const "eps") formal_captures in
                let cons_lhs =
                  call (App ("_ _", [ head; tail ])) formal_captures
                in
                let recursive_lhs = call tail formal_captures in
                let indexed_guards, indexed_diags =
                  typecheck_for_indexed_element_typ
                    ctx
                    env
                    origin
                    source_element_typ
                    head
                    source_element_sort
                in
                let false_condition =
                  Runtime_truth_decision_helper.false_rewrite_condition
                    ~helper_name:decision_name
                    decision_request
                in
                let body_conditions =
                  List.map
                    (fun condition -> EqCondition condition)
                    indexed_guards
                  @ [ false_condition
                    ; RewriteCond (recursive_lhs, Const ok_name)
                    ]
                in
                let statements =
                  [ generated helper_name origin (sort_decl result_sort)
                  ; generated
                      helper_name
                      origin
                      (op
                         op_name
                         (sort_ref spectec_terminals
                          :: List.map sort_ref capture_sorts)
                         result_sort
                         ~attrs:
                           (frozen_all (spectec_terminals :: capture_sorts)))
                  ; generated helper_name origin (op ok_name [] result_sort ~attrs:[ Ctor ])
                  ; generated helper_name origin (var head_var (sort_ref source_element_sort))
                  ; generated helper_name origin (var tail_var (sort_ref spectec_terminals))
                  ]
                  @ (capture_sorts
                     |> List.mapi (fun index sort ->
                       generated
                         helper_name
                         origin
                         (var
                            (indexed_capture_var
                               helper_name
                               refuter.index
                               prem_index
                               index)
                            (sort_ref sort))))
                  @ [ generated
                        helper_name
                        origin
                        (rl
                           ~label:(op_name ^ "-empty")
                           empty_lhs
                           (Const ok_name))
                    ; generated
                        helper_name
                        origin
                        (crl
                           ~label:(op_name ^ "-cons")
                           cons_lhs
                           (Const ok_name)
                           body_conditions)
                    ; generated
                        helper_name
                        origin
                        (crl
                           ~label:
                             (helper_name
                              ^ "-rule-refuted-"
                              ^ string_of_int refuter.index
                              ^ "-indexed-dependent-"
                              ^ string_of_int prem_index)
                           lhs
                           rhs
                           (append_prefix_conditions
                              prefix_conditions
                              (List.map
                                 (fun condition -> EqCondition condition)
                                 (source_result.guards @ capture_guards)
                               @ [ RewriteCond
                                     ( call source_term capture_terms
                                     , Const ok_name )
                                 ])))
                    ]
                in
                Some
                  (complete
                     statements
                     (source_result.diagnostics
                      @ capture_diags
                      @ indexed_diags)))
            | None, _ | _, None -> None))))
  | [] | _ :: _ :: _ -> None

let premise_refuter_rules
    ctx
    helper_name
    origin
    request
    refuter
    env
    prefix_conditions
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
  | Il.Ast.IfPr ({ it = Il.Ast.CmpE (`EqOp, _, left, right); _ } as exp) ->
    (match
       Runtime_truth_equality_pattern_refuter.refute
         ctx
         ~helper_name
         ~origin:prem_origin
         ~env
         ~refuter_index:refuter.index
         ~prem_index
         ~prefix_conditions
         ~lhs
         ~rhs:(rule_refuter_ok refuter)
         ~left
         ~right
     with
    | Some result -> complete result.statements result.diagnostics
    | None ->
    let lowered = Expr_translate.lower_bool_condition ctx env prem_origin exp in
    (match lowered.term with
    | Some term ->
      complete
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
               (append_prefix_conditions
                  prefix_conditions
                  (List.map
                     (fun condition -> EqCondition condition)
                     lowered.guards
                   @ [ EqCondition (EqCond (term, Const "false")) ])))
        ]
        lowered.diagnostics
    | None ->
      incomplete
        ~diagnostics:lowered.diagnostics
        ("IfPr premise `"
         ^ Il.Print.string_of_prem prem
         ^ "` did not lower to a Bool term for source refutation")))
  | Il.Ast.IfPr exp ->
    let lowered = Expr_translate.lower_bool_condition ctx env prem_origin exp in
    (match lowered.term with
    | Some term ->
      complete
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
               (append_prefix_conditions
                  prefix_conditions
                  (List.map
                     (fun condition -> EqCondition condition)
                     lowered.guards
                   @ [ EqCondition (EqCond (term, Const "false")) ])))
        ]
        lowered.diagnostics
    | None ->
      incomplete
        ~diagnostics:lowered.diagnostics
        ("IfPr premise `"
         ^ Il.Print.string_of_prem prem
         ^ "` did not lower to a Bool term for source refutation"))
  | Il.Ast.RulePr (rel_id, [], _mixop, exp) ->
    let components = rulepr_components ctx rel_id.it exp in
    if
      String.equal
        rel_id.it
        request.Runtime_truth_decision_helper.truth_request.rel_id
    then
      let lowered =
        Rule_components.lower_value_components ctx env prem_origin components
      in
      if List.exists Diagnostics.is_fatal lowered.diagnostics then
        incomplete
          ~diagnostics:lowered.diagnostics
          ("RulePr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` did not lower to bound Maude values")
      else
        match lowered.values with
        | Some (terms, _sorts) ->
        complete
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
                 (append_prefix_conditions
                    prefix_conditions
                    (List.map
                       (fun condition -> EqCondition condition)
                       lowered.guards
                     @ [ same_relation_no_hit_condition helper_name request terms ])))
          ]
          lowered.diagnostics
        | None ->
          incomplete
            ~diagnostics:lowered.diagnostics
            ("RulePr premise `"
             ^ Il.Print.string_of_prem prem
             ^ "` did not lower to already-bound Maude values")
    else
      (match
        Runtime_truth_deterministic_false.materialize
          ctx
          ~helper_name
          ~origin:prem_origin
          ~env
          ~label:
            (helper_name
             ^ "-rule-refuted-"
             ^ string_of_int refuter.index
             ^ "-deterministic-"
             ^ string_of_int prem_index)
          ~lhs
          ~rhs:(rule_refuter_ok refuter)
          ~rel_id
          ~exp
      with
      | Runtime_truth_deterministic_false.Materialized
          { statements; diagnostics } ->
        complete statements diagnostics
      | Runtime_truth_deterministic_false.Materialization_blocked
          { diagnostics; blockers } ->
        incomplete
          ~diagnostics
          ("deterministic RulePr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` has no source-complete false decision: "
           ^ String.concat "; " blockers)
      | Runtime_truth_deterministic_false.Not_deterministic_materialization ->
        (match
           indexed_dependent_false
             ctx
             helper_name
             prem_origin
             request
             refuter
             env
             prefix_conditions
             lhs
             (rule_refuter_ok refuter)
             prem_index
             rel_id
             components
         with
        | Some result -> result
        | None ->
        (match
          Runtime_truth_dependent_false.lower
            ctx
            prem_origin
            env
            ~rel_id:rel_id.it
            ~components
         with
        | Ok conditions ->
          complete
            [ generated
                helper_name
                prem_origin
                (crl
                   ~label:
                     (helper_name
                      ^ "-rule-refuted-"
                      ^ string_of_int refuter.index
                      ^ "-dependent-"
                      ^ string_of_int prem_index)
                   lhs
                   (rule_refuter_ok refuter)
                   (append_prefix_conditions prefix_conditions conditions))
            ]
            []
        | Error (Runtime_truth_dependent_false.Diagnostics diagnostics) ->
          incomplete
            ~diagnostics
            ("dependent RulePr premise `"
             ^ Il.Print.string_of_prem prem
             ^ "` did not lower to a false decision")
        | Error (Runtime_truth_dependent_false.Blocked blockers) ->
          incomplete
             ("dependent RulePr premise `"
             ^ Il.Print.string_of_prem prem
             ^ "` has no source-complete false decision: "
             ^ String.concat "; " blockers))))
  | Il.Ast.RulePr (_, _ :: _, _, _)
  | Il.Ast.LetPr _ | Il.Ast.ElsePr | Il.Ast.IterPr _ | Il.Ast.NegPr _ ->
    incomplete
      ("premise constructor in `"
       ^ Il.Print.string_of_prem prem
       ^ "` is not supported by finite no-hit refutation")

let indexed_head_refuter_rules
    ctx helper_name origin _request refuter input_terms components rule
  =
  let indexed =
    components
    |> List.mapi (fun index component -> index, indexed_source component)
    |> List.filter_map (function
      | index, Some (_index_source_id, source_exp, source_element_typ) ->
        Some (index, source_exp, source_element_typ)
      | _index, None -> None)
  in
  match indexed with
  | [ indexed_index, source_exp, source_element_typ ] ->
    let source_exp = source_preserving_iter_source source_exp in
    let source_element_typ =
      match source_element_typ with
      | Some typ -> Some typ
      | None -> flat_list_element_typ source_exp.note
    in
    (match source_element_typ with
    | None ->
      incomplete
        ("indexed head source `"
         ^ Il.Print.string_of_exp source_exp
         ^ "` has no list element type")
    | Some source_element_typ ->
      (match Expr_translate.carrier_sort_of_typ source_element_typ with
      | None ->
        incomplete
          ("indexed head source element type `"
           ^ Il.Print.string_of_typ source_element_typ
           ^ "` has no Maude carrier")
      | Some source_element_sort ->
        let rec lower_head env terms guards diagnostics index = function
          | [] ->
            Some
              ( env
              , List.rev terms
              , List.rev guards
              , List.rev diagnostics )
          | component :: rest ->
            if index = indexed_index then
              match nth_opt input_terms indexed_index with
              | None -> None
              | Some indexed_term ->
                lower_head
                  env
                  (indexed_term :: terms)
                  guards
                  diagnostics
                  (index + 1)
                  rest
            else
              let result =
                Expr_translate.lower_pattern_with_bindings
                  ctx
                  env
                  origin
                  component
              in
              (match result.pattern_term with
              | None -> None
              | Some term ->
                let env =
                  List.fold_left
                    (fun env (id, binding) ->
                      Expr_translate.add_var env id binding)
                    env
                    result.introduced_bindings
                in
                lower_head
                  env
                  (term :: terms)
                  (List.rev_append result.pattern_guards guards)
                  (List.rev_append result.pattern_diagnostics diagnostics)
                  (index + 1)
                  rest)
        in
        (match lower_head Expr_translate.empty_env [] [] [] 0 components with
        | None ->
          incomplete
            "indexed head rule has non-indexed components that do not lower to source patterns"
        | Some (env, pattern_terms, head_guards, head_diagnostics) ->
          let prefix_result =
            Premise_translate.translate_premises
              ~allow_runtime_search:true
              ctx
              env
              ~bound_conditions:head_guards
              ~escape_source_ids:[]
              ~bound_terms:pattern_terms
              origin
              rule.Analysis.Function_graph.prems
          in
          if List.exists Diagnostics.is_fatal prefix_result.diagnostics then
            incomplete
              ~diagnostics:(head_diagnostics @ prefix_result.diagnostics)
              "indexed head rule premises did not lower source-completely"
          else
            let source_result =
              Expr_translate.lower_sequence
                ctx
                prefix_result.env_after
                origin
                source_exp
            in
            (match source_result.term with
            | None ->
              incomplete
                ~diagnostics:
                  (head_diagnostics
                   @ prefix_result.diagnostics
                   @ source_result.diagnostics)
                ("indexed head source `"
                 ^ Il.Print.string_of_exp source_exp
                 ^ "` did not lower after source premises")
            | Some source_term ->
              let op_name =
                indexed_head_no_match_op helper_name refuter.index
              in
              let ok_name =
                indexed_head_no_match_ok_op helper_name refuter.index
              in
              let result_sort =
                indexed_head_no_match_sort helper_name refuter.index
              in
              let target_var =
                indexed_head_target_var helper_name refuter.index
              in
              let head_var =
                indexed_head_list_head_var helper_name refuter.index
              in
              let tail_var =
                indexed_head_list_tail_var helper_name refuter.index
              in
              let target = Var target_var in
              let head = Var head_var in
              let tail = Var tail_var in
              let call target source =
                indexed_head_no_match_call op_name target source
              in
              (match nth_opt input_terms indexed_index with
              | None ->
                incomplete "indexed head target component is not available"
              | Some target_term ->
                let lhs = rule_refuter_call refuter pattern_terms in
                let statements =
                  [ generated helper_name origin (sort_decl result_sort)
                  ; generated
                      helper_name
                      origin
                      (op
                         op_name
                         [ sort_ref source_element_sort
                         ; sort_ref spectec_terminals
                         ]
                         result_sort
                         ~attrs:
                           (frozen_all [ source_element_sort; spectec_terminals ]))
                  ; generated helper_name origin (op ok_name [] result_sort ~attrs:[ Ctor ])
                  ; generated helper_name origin (var target_var (sort_ref source_element_sort))
                  ; generated helper_name origin (var head_var (sort_ref source_element_sort))
                  ; generated helper_name origin (var tail_var (sort_ref spectec_terminals))
                  ; generated
                      helper_name
                      origin
                      (rl
                         ~label:(op_name ^ "-empty")
                         (call target (Const "eps"))
                         (Const ok_name))
                  ; generated
                      helper_name
                      origin
                      (crl
                         ~label:(op_name ^ "-cons")
                         (call target (App ("_ _", [ head; tail ])))
                         (Const ok_name)
                         [ EqCondition (BoolCond (App ("_=/=_", [ target; head ])))
                         ; RewriteCond (call target tail, Const ok_name)
                         ])
                  ; generated
                      helper_name
                      origin
                      (crl
                         ~label:
                           (helper_name
                            ^ "-rule-refuted-"
                            ^ string_of_int refuter.index
                            ^ "-indexed-head")
                         lhs
                         (rule_refuter_ok refuter)
                         (List.map
                            (fun condition -> EqCondition condition)
                            (head_guards
                             @ prefix_result.eq_conditions
                             @ source_result.guards)
                          @ prefix_result.rule_conditions
                          @ [ RewriteCond
                                ( call target_term source_term
                                , Const ok_name )
                            ]))
                  ]
                in
                complete
                  statements
                  (head_diagnostics
                   @ prefix_result.diagnostics
                   @ source_result.diagnostics))))))
  | [] | _ :: _ :: _ ->
    incomplete
      "source RuleD head pattern did not lower to Maude patterns"

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
    | None ->
      incomplete
        ("source RuleD `"
         ^ Option.value
             ~default:("RuleD[" ^ string_of_int index ^ "]")
             rule.Analysis.Function_graph.rule_id
         ^ "` head does not match the runtime truth arity")
    | Some components ->
      let lowered_head =
        Rule_components.lower_complete_head_patterns ctx origin components
      in
      (match lowered_head.terms with
      | None ->
        let indexed_head =
          indexed_head_refuter_rules
            ctx
            helper_name
            origin
            request
            refuter
            input_terms
            components
            rule
        in
        { indexed_head with
          diagnostics =
            if indexed_head.complete then
              indexed_head.diagnostics
            else
              lowered_head.diagnostics @ indexed_head.diagnostics
        ; blockers =
            if indexed_head.complete then
              indexed_head.blockers
            else
              ("source RuleD `"
               ^ Option.value
                   ~default:("RuleD[" ^ string_of_int index ^ "]")
                   rule.Analysis.Function_graph.rule_id
               ^ "` head pattern did not lower to Maude patterns")
              :: indexed_head.blockers
        }
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
        (* For a source rule with premises P1 ... Pn, refuting the whole
           conjunction is the finite disjunction

             not P1
             or P1 /\ not P2
             or ...
             or P1 /\ ... /\ P(n-1) /\ not Pn.

           We materialize one CRL per branch.  This is the point where
           source-bound variables introduced by earlier premises (for example
           an equality that binds a list used by a later indexed RulePr) become
           visible to the later false premise. *)
        let rec premise_refuters prefix index acc = function
          | [] -> acc
          | prem :: rest ->
            let prefix_result =
              Premise_translate.translate_premises
                ~allow_runtime_search:true
                ctx
                lowered_head.env
                ~bound_conditions:lowered_head.guards
                ~escape_source_ids:[]
                ~bound_terms:pattern_terms
                origin
                (List.rev prefix)
            in
            let prefix_conditions =
              List.map
                (fun condition -> EqCondition condition)
                (lowered_head.guards @ prefix_result.eq_conditions)
              @ prefix_result.rule_conditions
            in
            let current =
              if List.exists Diagnostics.is_fatal prefix_result.diagnostics then
                incomplete
                  ~diagnostics:prefix_result.diagnostics
                  ("source RuleD `"
                   ^ Option.value
                       ~default:("RuleD[" ^ string_of_int index ^ "]")
                       rule.Analysis.Function_graph.rule_id
                   ^ "` prefix premises before premise["
                   ^ string_of_int index
                   ^ "] did not lower source-completely")
              else
                premise_refuter_rules
                  ctx
                  helper_name
                  origin
                  request
                  refuter
                  prefix_result.env_after
                  prefix_conditions
                  lhs
                  index
                  prem
            in
            premise_refuters
              (prem :: prefix)
              (index + 1)
              (append_refuters acc current)
              rest
        in
        let premise_refuters =
          premise_refuters [] 1 (complete [] []) rule.prems
        in
        let statements = head_rules @ premise_refuters.statements in
        let has_refuter =
          match statements with
          | [] -> false
          | _ :: _ -> true
        in
        { statements
        ; diagnostics = lowered_head.diagnostics @ premise_refuters.diagnostics
        ; complete = has_refuter && premise_refuters.complete
        ; blockers =
            premise_refuters.blockers
            @
            if has_refuter then []
            else
              [ "source RuleD `"
                ^ Option.value
                    ~default:("RuleD[" ^ string_of_int index ^ "]")
                    rule.Analysis.Function_graph.rule_id
                ^ "` has no generated head or premise refuter"
              ]
        })
  in
  rules
  |> List.mapi (fun index rule -> lower_rule (index + 1) rule)
  |> List.fold_left append_refuters (complete [] [])

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
  let full = Var (full_candidates_var_name helper_name) in
  let visited = Var (visited_var_name helper_name) in
  let call =
    no_path_call ~helper_name request input_terms full (Const "eps") visited
  in
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

let no_path_visited_rule helper_name origin request =
  let input_terms = input_vars request helper_name in
  let full = Var (full_candidates_var_name helper_name) in
  let candidates = Var (candidates_var_name helper_name) in
  let visited = Var (visited_var_name helper_name) in
  let call =
    no_path_call ~helper_name request input_terms full candidates visited
  in
  [ generated
      helper_name
      origin
      (crl
         ~label:(helper_name ^ "-no-path-visited")
         call.lhs
         call.rhs
         [ EqCondition
             (BoolCond
                (App
                   ( "contains"
                   , [ App (visited_key_op helper_name, input_terms); visited ]
                   )))
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
    let full = Var (full_candidates_var_name helper_name) in
    let rest = Var (rest_var_name helper_name) in
    let visited = Var (visited_var_name helper_name) in
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
    let current =
      no_path_call ~helper_name request input_terms full candidates visited
    in
    let without_current =
      no_path_call ~helper_name request input_terms full rest visited
    in
    let left_terms = prefix @ [ left; witness ] in
    let right_terms = prefix @ [ witness; right ] in
    let next_visited =
      App
        ( "_ _"
        , [ visited; App (visited_key_op helper_name, input_terms) ] )
    in
    let without_left =
      no_path_call ~helper_name request left_terms full full next_visited
    in
    let without_right =
      no_path_call ~helper_name request right_terms full full next_visited
    in
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
  let no_path =
    no_path_call
      ~helper_name
      request
      input_terms
      candidates
      candidates
      (Const "eps")
  in
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
  let refuters =
    rule_refuter_rules ctx helper_name origin request rules
  in
  { refuters with
    statements =
      generated_input_vars helper_name origin request
      @ no_path_vars
          helper_name
          origin
          domain.Runtime_witness_proof.transitive.witness_source_id
      @ all_rules_rule helper_name origin request rules
      @ refuters.statements
      @ no_path_empty_rule helper_name origin request
      @ no_path_visited_rule helper_name origin request
      @ no_path_step_rules helper_name origin request domain
      @ no_hit_entry_rule helper_name origin request
  }

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

let unsupported ctx origin request domain blockers =
  let rules = base_rules request domain |> local_rule_names in
  let rules =
    match rules with
    | [] -> "no local RuleD"
    | _ -> String.concat ", " rules
  in
  let blocker_text =
    match blockers with
    | [] -> ""
    | _ -> "; blockers: " ^ String.concat "; " blockers
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
       ^ rules
       ^ blocker_text)
    ~suggestion:
      "Implement relation-local RuleD no-hit helpers first, then connect dependent runtimeTruthFalse obligations and the finite candidate loop; do not encode failed positive search as false"
    ~source_echo:(Runtime_truth_decision_helper.reason request)
    ()

let unsupported_acyclic ctx origin request blockers =
  let blocker_text =
    match blockers with
    | [] -> ""
    | _ -> "; blockers: " ^ String.concat "; " blockers
  in
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor:"RuntimeTruthNoHit/materializer/acyclic/refuter-unimplemented"
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason:
      ("acyclic runtime truth no-hit needs source-complete per-RuleD refuters before it can emit runtimeTruthFalse"
       ^ blocker_text)
    ~suggestion:
      "Implement the listed source-rule false branches; do not encode failed positive search as false"
    ~source_echo:(Runtime_truth_decision_helper.reason request)
    ()

let finite_transitive ctx ~helper_name ~origin request domain =
  let call = no_hit_call ~helper_name request in
  let rules = base_rules request domain in
  let no_hit =
    no_hit_rules ctx helper_name origin request domain
  in
  let diagnostics =
    if no_hit.complete then
      no_hit.diagnostics
    else
      no_hit.diagnostics @ [ unsupported ctx origin request domain no_hit.blockers ]
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    { statements = []; conditions = []; diagnostics }
  else
    { statements =
        helper_surface helper_name origin request rules
        @ no_hit.statements
    ; conditions = [ RewriteCond (call.lhs, call.rhs) ]
    ; diagnostics
    }

let acyclic_no_hit_entry_rule helper_name origin request =
  let input_terms = input_vars request helper_name in
  let no_hit = no_hit_call ~helper_name request in
  [ generated
      helper_name
      origin
      (crl
         ~label:(helper_name ^ "-acyclic-no-hit")
         (App (no_hit.op, input_terms))
         no_hit.rhs
         [ RewriteCond
             (all_rules_call ~helper_name input_terms, all_rules_ok helper_name)
         ])
  ]

let acyclic ctx ~helper_name ~origin request =
  let call = no_hit_call ~helper_name request in
  let rules = local_rules request in
  let refuters =
    rule_refuter_rules ctx helper_name origin request rules
  in
  let diagnostics =
    if refuters.complete then
      refuters.diagnostics
    else
      refuters.diagnostics
      @ [ unsupported_acyclic ctx origin request refuters.blockers ]
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    { statements = []; conditions = []; diagnostics }
  else
    { statements =
        no_hit_surface helper_name origin request
        @ all_rules_surface helper_name origin request
        @ rule_refuter_surface helper_name origin request rules
        @ generated_input_vars helper_name origin request
        @ all_rules_rule helper_name origin request rules
        @ refuters.statements
        @ acyclic_no_hit_entry_rule helper_name origin request
    ; conditions = [ RewriteCond (call.lhs, call.rhs) ]
    ; diagnostics
    }
