val relation_call : Il.Ast.id -> Maude_ir.term list -> Maude_ir.term

val relation_equational_view_call :
  Il.Ast.id -> Maude_ir.term list -> Maude_ir.term

val fresh_result_var :
  fallback:string -> label:string -> Origin.t -> Il.Ast.id -> Maude_ir.sort ->
  Maude_ir.term

val lower_input_values :
  Context.t ->
  Expr_translate.env ->
  Origin.t ->
  Il.Ast.exp list ->
  Maude_ir.term list option * Maude_ir.eq_condition list * Diagnostics.t list

val tuple_pattern_from_components :
  Relation_shape.component list ->
  Maude_ir.term list ->
  Maude_ir.term option * string list

val result_output_condition :
  string list -> Maude_ir.term -> Maude_ir.term -> Maude_ir.eq_condition
