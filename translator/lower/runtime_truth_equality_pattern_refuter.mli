type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val refute :
  Context.t ->
  helper_name:string ->
  origin:Origin.t ->
  env:Expr_translate.env ->
  refuter_index:int ->
  prem_index:int ->
  prefix_conditions:Maude_ir.rule_condition list ->
  lhs:Maude_ir.term ->
  rhs:Maude_ir.term ->
  left:Il.Ast.exp ->
  right:Il.Ast.exp ->
  result option
