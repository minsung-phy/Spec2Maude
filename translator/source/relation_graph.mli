type relation_kind =
  | Execution
  | Execution_star
  | Deterministic_candidate
  | Predicate_candidate
  | Unknown

val string_of_relation_kind : relation_kind -> string
val classify_mixop : Il.Ast.mixop -> relation_kind
val string_of_mixop : Il.Ast.mixop -> string
val eq_mixop : Il.Ast.mixop -> Il.Ast.mixop -> bool
val mixop_shape_text : Il.Ast.mixop -> string
val exp_components : Il.Ast.exp -> Il.Ast.exp list
val exp_components_for_count : int -> Il.Ast.exp -> Il.Ast.exp list option
