type complement_alternative =
  { conditions : Maude_ir.rule_condition list
  ; established : Maude_ir.eq_condition list
  }

type complement_result =
  { output : Reld_result.output
  ; alternatives : complement_alternative list
  ; support_statements : Maude_ir.generated list
  }

val complement :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Analysis.Relation_graph.relation_kind ->
  Il.Ast.mixop ->
  Relation_shape.execution_shape ->
  Maude_ir.sort list ->
  Origin.t ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  Il.Ast.rule list ->
  complement_result
