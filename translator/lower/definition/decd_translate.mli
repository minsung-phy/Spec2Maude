type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val translate :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Il.Ast.param list ->
  Il.Ast.typ ->
  Il.Ast.clause list ->
  output
