open Maude_ir

open Runtime_truth_worklist_core
open Runtime_truth_worklist_premise
open Runtime_truth_worklist_positive

type special_edge =
  | No_special_edge
  | Special_edge of generated list * rule_condition list * Diagnostics.t list
  | Special_edge_blocked of Diagnostics.t list

let lower ctx item relations relation index rule =
  let origin, declarations, bind_diagnostics, head =
    Runtime_truth_worklist_rule.lower_head ctx item relation index rule
  in
  match head.terms with
  | None -> [], bind_diagnostics @ head.diagnostics
  | Some terms ->
    let history, _ = history_var head.local_names in
    let next_history = push item relation terms history in
    let special_edge =
      match transitive_domain rule with
      | Some transitive ->
        (match
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
          Special_edge
            (indexed.statements, [ indexed.true_condition ], diagnostics)
        | Blocked diagnostics -> Special_edge_blocked diagnostics)
      | None ->
        (match target_chain rule with
        | None -> No_special_edge
        | Some target ->
          (match
             target_chain_edge
               ctx item relations relation rule target head.env terms next_history true
           with
          | Materialized (statements, [ conditions ], diagnostics) ->
            Special_edge (statements, conditions, diagnostics)
          | Materialized (_, _, diagnostics) ->
            Special_edge_blocked
              (diagnostics @ [ diagnostic ctx item origin
                 "RuntimeTruthWorklist/target-chain/positive-alternatives"
                 "target-chain prove edge did not produce exactly one source conjunction"
                 "Keep the edge blocked until its planned guards retain one ordered positive path"
                 rule.source.source_echo ])
          | Blocked diagnostics -> Special_edge_blocked diagnostics))
    in
    let children =
      match special_edge with
      | No_special_edge ->
        lower_positive_children
          ctx item relations origin Runtime_truth_worklist_indexed.Rule_premise
          index terms head.env next_history
          (Runtime_truth_scc.scheduled_premises rule)
      | Special_edge_blocked diagnostics ->
        { env = head.env
        ; eq_conditions = []
        ; rule_conditions = []
        ; diagnostics
        ; statements = []
        ; complete = false
        }
      | Special_edge (edge_statements, edge_conditions, edge_diagnostics) ->
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
      let rhs =
        (Runtime_truth_worklist_helper.invocation
           ~helper_name:item.name item.request).proved_rhs
      in
      let head_guards =
        Runtime_truth_worklist_rule.emitted_head_guards ctx terms head.guards
      in
      let conditions =
        EqCondition
          (BoolCond
             (App
                ("_=/=_",
                 [ visited item relation terms history; Const "true" ])))
        :: List.map (fun guard -> EqCondition guard)
             (head_guards @ children.eq_conditions)
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
      else
        ( children.statements @ declarations
          @ [ generated item origin
                (crl ~label:(item.name ^ "-prove-" ^ string_of_int index)
                   lhs rhs conditions) ]
        , diagnostics )
