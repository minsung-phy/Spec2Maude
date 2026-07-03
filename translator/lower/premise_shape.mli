val flat_optional_element_typ : Il.Ast.typ -> Il.Ast.typ option

val flat_list_element_typ : Il.Ast.typ -> Il.Ast.typ option

val zip_source_descriptor :
  Il.Ast.typ ->
  (Helper.iter_map_source_item_shape * Il.Ast.typ) option

val typecheck_for_sort :
  Maude_ir.sort ->
  Maude_ir.term ->
  Maude_ir.term ->
  Maude_ir.term

val is_sequence_sort : Maude_ir.sort -> bool

val lower_with_source_carrier :
  Context.t ->
  Expr_translate.env ->
  Origin.t ->
  Il.Ast.exp ->
  Expr_translate.result
