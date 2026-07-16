type result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type pattern_result =
  { pattern_term : Maude_ir.term option
  ; pattern_guards : Maude_ir.eq_condition list
  ; introduced_bindings : (string * Expr_env.binding) list
  ; pattern_diagnostics : Diagnostics.t list
  }

val with_term : Maude_ir.term -> result
val with_diagnostics : Diagnostics.t list -> result
val append_result_metadata :
  result list -> Maude_ir.eq_condition list * Diagnostics.t list
val terms : result list -> Maude_ir.term list option
