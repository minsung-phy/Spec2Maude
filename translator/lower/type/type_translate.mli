type result = Type_result.result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val preload_typd_registry :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Il.Ast.param list ->
  Il.Ast.inst list ->
  unit

val translate_typd :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  Il.Ast.param list ->
  Il.Ast.inst list ->
  result
