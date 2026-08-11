type t

val certify :
  Context.t ->
  relation_id:Il.Ast.id ->
  context:Execution_context_certificate.t ->
  value_cases:(Il.Ast.mixop * int) list ->
  t option
