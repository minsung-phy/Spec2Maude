type error =
  | Diagnostics of Diagnostics.t list
  | Blocked of string list

val lower :
  Context.t ->
  Origin.t ->
  Expr_translate.env ->
  rel_id:string ->
  components:Il.Ast.exp list ->
  (Maude_ir.rule_condition list, error) result
