open Runtime_truth_worklist_core

let lower_head ctx item _relation _rule_index rule =
  let source = rule.Runtime_truth_scc.source in
  let components = Analysis.Relation_graph.exp_components source.head in
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
