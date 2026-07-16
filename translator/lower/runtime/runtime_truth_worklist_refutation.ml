open Maude_ir
open Il.Ast
open Util.Source

open Runtime_truth_worklist_core
open Runtime_truth_worklist_positive

module Refutation : sig
  val lower_rule :
    Context.t -> item -> relation list -> relation -> int ->
    Runtime_truth_scc.rule -> generated list * Diagnostics.t list
  val solver : item -> relation -> (int * Runtime_truth_scc.rule) list -> generated list
end = struct

let match_equations item relation index terms =
  let vars, _ = input_vars Local_name.empty relation.sorts in
  [ generated item item.origin
      (eq (App (match_op item index, terms)) (Const "true"))
  ; generated item item.origin
      (eq ~attrs:[ Owise ] (App (match_op item index, vars)) (Const "false"))
  ]

type false_child =
  | Refutable of generated list * Diagnostics.t list
  | Irrefutable of Diagnostics.t list
  | False_blocked of Diagnostics.t list

let deterministic_false_child
    ctx item relations origin rule_index prem_index head head_guards
    (state : positive_children) lhs rhs history premise
  =
  let prefix =
    EqCondition (BoolCond (App (match_op item rule_index, head)))
    :: List.map (fun guard -> EqCondition guard) head_guards
    @ List.map (fun guard -> EqCondition guard) state.eq_conditions
    @ state.rule_conditions
  in
  let source_boolean_false prem exp =
    let premise_origin =
      Origin.with_child
        ~source_echo:(Il.Print.string_of_prem prem)
        origin ("premise-" ^ string_of_int prem_index)
        ~ast_constructor:"IfPr" prem.at
    in
    match
      Runtime_truth_total_equality.source_boolean_alternatives
        ctx state.env premise_origin exp
    with
    | Error blockers ->
      False_blocked
        (List.map (Runtime_truth_total_equality.diagnostic ctx) blockers)
    | Ok (_, [], diagnostics) -> Irrefutable diagnostics
    | Ok (_, failures, diagnostics) ->
      let rules =
        failures
        |> List.mapi (fun alternative failure ->
          let conditions =
            prefix @ List.map (fun condition -> EqCondition condition) failure
            |> Condition_closure.normalize_rule_conditions
                 ~constructor_op:
                   (worklist_pattern_certificate ctx item relations)
                 [ lhs ]
          in
          generated item premise_origin
            (crl
               ~label:
                 (item.name ^ "-rule-refute-" ^ string_of_int rule_index
                  ^ "-source-boolean-" ^ string_of_int prem_index
                  ^ "-" ^ string_of_int (alternative + 1))
               lhs rhs conditions))
      in
      Refutable (state.statements @ rules, diagnostics)
  in
  match premise with
  | Runtime_truth_scc.Finite_rule_call _ as premise ->
    (match recursive_call ctx item relations state.env history premise false with
    | Some (condition, guards, diagnostics) ->
      let conditions =
        prefix @ List.map (fun guard -> EqCondition guard) guards @ [ condition ]
        |> Condition_closure.normalize_rule_conditions
             ~constructor_op:
               (worklist_pattern_certificate ctx item relations)
             [ lhs ]
      in
      Refutable
        ( state.statements @ [ generated item origin
              (crl
                 ~label:
                   (item.name ^ "-rule-refute-" ^ string_of_int rule_index
                    ^ "-" ^ string_of_int prem_index)
                 lhs rhs conditions) ]
        , diagnostics )
    | None -> False_blocked [])
  | Runtime_truth_scc.Externally_validated _ -> Irrefutable []
  | Runtime_truth_scc.Source_boolean prem ->
    (match prem.it with
    | IfPr ({ it = CmpE (`EqOp, _, left, right); _ } as exp) ->
      (match
         Runtime_truth_equality_pattern_refuter.refute
           ctx ~helper_name:item.name ~origin ~env:state.env
           ~refuter_index:rule_index ~prem_index
           ~prefix_conditions:prefix ~lhs ~rhs ~left ~right
       with
      | Some result when result.statements <> [] ->
        Refutable (state.statements @ result.statements, result.diagnostics)
      | Some result -> Irrefutable result.diagnostics
      | None -> source_boolean_false prem exp)
    | IfPr exp -> source_boolean_false prem exp
    | RulePr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ ->
      False_blocked
        [ diagnostic ctx item origin
            "RuntimeTruthWorklist/false/source-boolean-classification"
            "runtime SCC marked a non-IfPr premise as a source Boolean observer"
            "Keep Source_boolean construction at the IfPr AST boundary"
            (Some (Il.Print.string_of_prem prem)) ] )
  | Runtime_truth_scc.Deterministic_total prem ->
    (match prem.it with
    | IfPr _ ->
      False_blocked
        [ diagnostic ctx item origin
            "RuntimeTruthWorklist/false/deterministic-classification"
            "IfPr reached Deterministic_total without a source Boolean observer proof"
            "Classify IfPr separately and prove its false alternatives from the source AST"
            (Some (Il.Print.string_of_prem prem)) ]
    | LetPr (_quants, left, right) ->
      (match
         Runtime_truth_equality_pattern_refuter.refute
           ctx ~helper_name:item.name ~origin ~env:state.env
           ~refuter_index:rule_index ~prem_index
           ~prefix_conditions:prefix ~lhs ~rhs ~left ~right
       with
      | Some result when result.statements <> [] ->
        Refutable (state.statements @ result.statements, result.diagnostics)
      | Some result -> Irrefutable result.diagnostics
      | None -> False_blocked [])
    | RulePr (rel_id, [], _, exp) ->
      (match Runtime_truth_deterministic_false.materialize
               ~prefix_conditions:prefix
               ctx ~helper_name:item.name ~origin ~env:state.env
               ~label:
                 (item.name ^ "-rule-refute-" ^ string_of_int rule_index
                  ^ "-det-" ^ string_of_int prem_index)
               ~lhs ~rhs ~rel_id ~exp with
      | Runtime_truth_deterministic_false.Materialized result ->
        Refutable (state.statements @ result.statements, result.diagnostics)
      | Materialization_blocked { diagnostics; _ } ->
        False_blocked diagnostics
      | Not_deterministic_materialization ->
        (* A validation-only ground leaf is guaranteed by the selected
           externally validated profile; it cannot refute this RuleD. *)
        Irrefutable [])
    | RulePr (_, _ :: _, _, _) | ElsePr | IterPr _ | NegPr _ ->
      False_blocked [])
  | Runtime_truth_scc.Deterministic_binding_iter _ ->
    Irrefutable []
  | Runtime_truth_scc.Finite_iter finite ->
    let identity =
      { Runtime_truth_worklist_indexed.phase =
          Runtime_truth_worklist_indexed.Rule_premise
      ; rule_index
      ; premise_index = Some prem_index
      }
    in
    let edge, diagnostics =
      match indexed_edge ctx item relations origin identity
              state.env history finite.premise with
      | Some indexed, diagnostics -> Some indexed, diagnostics
      | None, diagnostics ->
        let forall, forall_diagnostics =
          forall_edge ctx item relations origin identity state.env history
            finite.premise finite.body
        in
        forall, diagnostics @ forall_diagnostics
    in
    (match edge, diagnostics with
    | Some indexed, diagnostics ->
      (match indexed.false_condition with
      | Some false_condition ->
        let conditions =
          prefix @ [ false_condition ]
          |> Condition_closure.normalize_rule_conditions
               ~constructor_op:
                 (worklist_pattern_certificate ctx item relations)
               [ lhs ]
        in
        Refutable
          ( state.statements @ indexed.statements
            @ [ generated item origin
                  (crl
                     ~label:
                       (item.name ^ "-rule-refute-" ^ string_of_int rule_index
                        ^ "-indexed-" ^ string_of_int prem_index)
                     lhs rhs conditions) ]
          , diagnostics )
      | None ->
        False_blocked
          (diagnostics
           @ [ diagnostic ctx item origin
                 "RuntimeTruthWorklist/false/indexed-mode"
                 "indexed premise was materialized without its decision-mode refuter"
                 "Request Decide mode before constructing an indexed false edge"
                 None ]))
    | None, diagnostics -> False_blocked diagnostics)
  | Runtime_truth_scc.Finite_domain_call _
  | Runtime_truth_scc.Finite_successor_call _ -> False_blocked []

let lower_rule ctx item relations relation index rule =
  let origin, declarations, bind_diagnostics, head =
    lower_head ctx item relation index rule
  in
  match head.terms with
  | None -> [], bind_diagnostics @ head.diagnostics
  | Some terms ->
    let args, names = input_vars head.local_names relation.sorts in
    let history, _ = history_var names in
    let call = App (rule_refute_op item index, args @ [ history ]) in
    let refuted = (Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request).refuted_rhs in
    let mismatch =
      generated item origin
        (crl ~label:(item.name ^ "-rule-mismatch-" ^ string_of_int index) call refuted
           [ EqCondition (BoolCond (App ("not_", [ App (match_op item index, args) ]))) ])
    in
    let lhs = App (rule_refute_op item index, terms @ [ history ]) in
    let head_guard_rules, head_guard_diagnostics, head_guard_blocked =
      match
        Runtime_truth_head_guard_refutation.complement
          ~pattern_certificate:(worklist_pattern_certificate ctx item relations)
          ~bound_terms:terms head.guards
      with
      | Runtime_truth_head_guard_refutation.Complete alternatives ->
        ( alternatives
          |> List.mapi (fun guard_index alternative ->
            let conditions =
              EqCondition (BoolCond (App (match_op item index, terms)))
              :: List.map (fun guard -> EqCondition guard) alternative
              |> Condition_closure.normalize_rule_conditions
                   ~constructor_op:
                     (worklist_pattern_certificate ctx item relations)
                   [ lhs ]
            in
            generated item origin
              (crl
                 ~label:
                   (item.name ^ "-rule-head-guard-" ^ string_of_int index
                    ^ "-" ^ string_of_int (guard_index + 1))
                 lhs refuted conditions))
        , []
        , false )
      | Runtime_truth_head_guard_refutation.Blocked reason ->
        ( []
        , [ diagnostic ctx item origin
              "RuntimeTruthWorklist/false/head-guard-complement"
              ("matched RuleD head has a guard without a structurally total false refutation: "
               ^ reason)
              "Keep this runtime truth query Unsupported until every head guard has a total source-derived complement"
              rule.source.source_echo ]
        , true )
    in
    let false_children =
      match transitive_domain rule with
      | Some transitive ->
        (match
             transitive_edge ctx item relations relation rule
             { Runtime_truth_worklist_indexed.phase =
                 Runtime_truth_worklist_indexed.Transitive
             ; rule_index = index
             ; premise_index = None
             }
             transitive head.env terms (push item relation terms history) false
         with
        | Materialized
            ((indexed : Runtime_truth_worklist_indexed.result), diagnostics) ->
          (match indexed.false_condition with
          | Some false_condition ->
            let conditions =
              EqCondition (BoolCond (App (match_op item index, terms)))
              :: List.map (fun guard -> EqCondition guard) head.guards
              @ [ false_condition ]
              |> Condition_closure.normalize_rule_conditions
                   ~constructor_op:
                     (worklist_pattern_certificate ctx item relations)
                   [ lhs ]
            in
            [ Refutable
                ( indexed.statements
                  @ [ generated item origin
                        (crl
                           ~label:(item.name ^ "-transitive-refute-" ^ string_of_int index)
                           lhs refuted conditions) ]
                , diagnostics ) ]
          | None ->
            [ False_blocked
                (diagnostics
                 @ [ diagnostic ctx item origin
                       "RuntimeTruthWorklist/false/transitive-mode"
                       "transitive edge was materialized without its decision-mode refuter"
                       "Request Decide mode before constructing a transitive false edge"
                       rule.source.source_echo ]) ])
        | Blocked diagnostics -> [ False_blocked diagnostics ])
      | None ->
      match target_chain rule with
      | Some target ->
        (match
         target_chain_edge ctx item relations relation rule target head.env terms
             (push item relation terms history) false
         with
        | Materialized (statements, alternatives, diagnostics) ->
          let rules =
            alternatives |> List.mapi (fun alternative edge_conditions ->
              let conditions =
                EqCondition (BoolCond (App (match_op item index, terms)))
                :: List.map (fun guard -> EqCondition guard) head.guards
                @ edge_conditions
                |> Condition_closure.normalize_rule_conditions
                     ~constructor_op:
                       (worklist_pattern_certificate ctx item relations)
                     [ lhs ]
              in
              generated item origin
                (crl
                   ~label:
                     (item.name ^ "-target-chain-refute-" ^ string_of_int index
                      ^ "-" ^ string_of_int (alternative + 1))
                   lhs refuted conditions))
          in
          [ Refutable (statements @ rules, diagnostics) ]
        | Blocked diagnostics -> [ False_blocked diagnostics ])
      | None ->
        let rec children prefix index = function
          | [] -> []
          | (source_index, premise) as indexed_premise :: rest ->
            let state =
              lower_positive_children
                ctx item relations origin Runtime_truth_worklist_indexed.Rule_premise
                index terms head.env
                (push item relation terms history) (List.rev prefix)
            in
            let child =
              if state.complete then
                deterministic_false_child
                  ctx item relations origin index source_index
                  terms head.guards state lhs refuted
                  (push item relation terms history) premise
              else
                False_blocked state.diagnostics
            in
            child :: children (indexed_premise :: prefix) index rest
        in
        children [] index (Runtime_truth_scc.scheduled_premises rule)
    in
    let blocked = head_guard_blocked ||
      List.exists (function False_blocked _ -> true | _ -> false) false_children
    in
    let child_rules = false_children |> List.concat_map (function
      | Refutable (statements, _) -> statements
      | Irrefutable _ | False_blocked _ -> [])
    in
    let child_diagnostics = false_children |> List.concat_map (function
      | Refutable (_, diagnostics) | Irrefutable diagnostics
      | False_blocked diagnostics -> diagnostics)
    in
    let blockers =
      if blocked then
        [ diagnostic ctx item origin
            "RuntimeTruthWorklist/false/open-child"
            "source RuleD AND child has no total false edge, so exhaustive rule refutation is unavailable"
            "Materialize this child refutation before using failed rule search as false"
            rule.source.source_echo ]
      else []
    in
    ( declarations @ match_equations item relation index terms
      @ [ mismatch ]
      @ head_guard_rules
      @ child_rules
    , bind_diagnostics @ head.diagnostics @ head_guard_diagnostics
      @ child_diagnostics @ blockers )

(* The Tarjan-planned SCC history is an unfounded-set certificate: a repeated
   goal closes a cycle, while every source rule must still refute. *)
let solver item relation indexed_rules =
  let invocation = Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request in
  let args, names = input_vars Local_name.empty relation.sorts in
  let history, _ = history_var names in
  let goal_term = goal item relation args in
  let refute_call = App (refute_op item relation.id, args @ [ history ]) in
  let all_call = App (all_op item relation.id, args @ [ App ("_ _", [ history; goal_term ]) ]) in
  let cycle =
    generated item item.origin
      (crl ~label:(item.name ^ "-unfounded-cycle-" ^ Naming.sanitize relation.id)
         refute_call invocation.refuted_rhs
         [ EqCondition (BoolCond (visited item relation args history)) ])
  in
  let all_conditions = indexed_rules |> List.map (fun (index, _) ->
    RewriteCond (App (rule_refute_op item index, args @ [ App ("_ _", [ history; goal_term ]) ]), invocation.refuted_rhs))
  in
  let all_rule =
    generated item item.origin
      (crl ~label:(item.name ^ "-all-rules-" ^ Naming.sanitize relation.id)
         all_call invocation.refuted_rhs all_conditions)
  in
  let exhaustive =
    generated item item.origin
      (crl ~label:(item.name ^ "-unfounded-certificate-" ^ Naming.sanitize relation.id)
         refute_call invocation.refuted_rhs
         [ EqCondition
             (BoolCond
                (App
                   ("_=/=_",
                    [ visited item relation args history; Const "true" ])))
         ; RewriteCond (all_call, invocation.refuted_rhs)
         ])
  in
  [ cycle; all_rule; exhaustive ]

end
