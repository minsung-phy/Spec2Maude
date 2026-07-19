open Runtime_truth_worklist_core

let rec take count acc values =
  if count = 0 then List.rev acc
  else
    match values with
    | [] -> List.rev acc
    | value :: values -> take (count - 1) (value :: acc) values

let lower_head_components ctx item rule components =
  let source = rule.Runtime_truth_scc.source in
  let origin =
    Origin.with_child ?source_echo:source.source_echo item.origin
      ("RuleD/" ^ Option.value ~default:"_" source.rule_id)
      ~ast_constructor:"RuleD" source.origin.region
  in
  let names =
    Reld_rule_lowering.local_names_for_rule_parts
      source.binds source.head source.prems
  in
  let env, declarations, bind_diagnostics, names =
    Reld_rule_lowering.translate_rule_binds
      ctx origin names source.binds
  in
  let lowered =
    Runtime_truth_rule_components.lower_complete_head_patterns
      names ~env ctx origin components
  in
  origin, declarations, bind_diagnostics, lowered

let lower_head ctx item _relation _rule_index rule =
  let components =
    Analysis.Relation_graph.exp_components rule.Runtime_truth_scc.source.head
  in
  lower_head_components ctx item rule components

let lower_head_prefix ctx item _relation _rule_index rule count =
  let components =
    Analysis.Relation_graph.exp_components rule.Runtime_truth_scc.source.head
    |> take count []
  in
  lower_head_components ctx item rule components
