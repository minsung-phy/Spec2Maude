type source =
  { component_index : int
  ; source_exp : Il.Ast.exp
  ; element_typ : Il.Ast.typ option
  }

val single_source : Il.Ast.exp list -> source option
