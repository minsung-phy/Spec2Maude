type blocker

type t =
  | Complete of Maude_ir.rule_condition list
  | Blocked of
      { diagnostics : Diagnostics.t list
      ; blockers : blocker list
      }

val blocker_reason : blocker -> string
val blocker_diagnostic : Context.t -> blocker -> Diagnostics.t

val lower :
  Context.t ->
  Origin.t ->
  Expr_env.t ->
  rel_id:string ->
  components:Il.Ast.exp list ->
  t
