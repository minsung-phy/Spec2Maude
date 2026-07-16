type typd_error =
  | Nested_sequence
  | Iteration_guard of Il.Ast.iter
  | Tuple_carrier

val for_expression : Il.Ast.typ -> Maude_ir.sort option
val for_typd : Context.t -> Il.Ast.typ -> (Maude_ir.sort, typd_error) result

val primitive_numeric_alias_sort :
  Context.t -> Il.Ast.typ -> Maude_ir.sort option
val raw_numeric_sort_of_numtyp : Il.Ast.numtyp -> Maude_ir.sort option
val raw_numeric_sort_of_typ : Context.t -> Il.Ast.typ -> Maude_ir.sort option
val numeric_conversion_preserves_runtime_representation :
  Il.Ast.numtyp -> Il.Ast.numtyp -> bool
val numeric_sort_coercion_preserves_runtime_representation :
  Maude_ir.sort -> Maude_ir.sort -> bool
val is_raw_numeric_sort : Maude_ir.sort -> bool
val is_nat_int_sort : Maude_ir.sort -> bool
val is_sequence_sort : Maude_ir.sort -> bool
val is_nat_sort : Maude_ir.sort -> bool
val typ_is_nat : Context.t -> Il.Ast.typ -> bool
