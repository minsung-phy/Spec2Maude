val typ_is_iter : Il.Ast.typ -> bool
val is_flat_list_typ : Il.Ast.typ -> bool
val is_flat_optional_typ : Il.Ast.typ -> bool
val is_nested_list_typ : Il.Ast.typ -> bool
val is_optional_list_typ : Il.Ast.typ -> bool
val is_list_optional_typ : Il.Ast.typ -> bool
val typ_components : Il.Ast.typ -> (Il.Ast.exp * Il.Ast.typ) list
val mixop_is_hole_only : Il.Ast.mixop -> bool
