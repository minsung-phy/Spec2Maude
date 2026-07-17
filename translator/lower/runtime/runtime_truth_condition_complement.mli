type proof = private
  { positive : Maude_ir.eq_condition list
  ; failures : Maude_ir.eq_condition list list
  ; diagnostics : Diagnostics.t list
  }

type equality_proof = private
  { left : Maude_ir.term
  ; right : Maude_ir.term
  ; conditions : proof
  }

val source_condition_blocker :
  Origin.t ->
  Il.Ast.exp ->
  reason:string ->
  Runtime_truth_totality.blocker

val false_conditions :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.cmpop ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  ((Maude_ir.eq_condition list * Diagnostics.t list),
   Runtime_truth_totality.blocker list) result

val source_equality_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  (equality_proof, Runtime_truth_totality.blocker list) result

val source_definedness_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  (proof, Runtime_truth_totality.blocker list) result

val source_boolean_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  (proof, Runtime_truth_totality.blocker list) result
