type output = Reld_common.output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val translate :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Il.Ast.param list ->
  Il.Ast.mixop ->
  Il.Ast.typ ->
  Il.Ast.rule list ->
  output
