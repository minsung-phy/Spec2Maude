type source =
  { generator_id : Il.Ast.id
  ; source_exp : Il.Ast.exp
  ; binding : Expr_env.binding
  ; item_shape : Helper_request.iter_map_source_item_shape
  ; head_term : Maude_ir.term
  ; tail_var : string
  }

val match_condition :
  Context.t ->
  Origin.t ->
  pattern_exp:Il.Ast.exp ->
  body_exp:Il.Ast.exp ->
  iter:Il.Ast.iter ->
  subject_item:Maude_ir.term ->
  subject_tail_var:string ->
  sources:source list ->
  captures:Helper_request.capture list ->
  body_conditions:Maude_ir.eq_condition list ->
  subject:Maude_ir.term ->
  Maude_ir.eq_condition
