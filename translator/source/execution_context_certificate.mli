type t

val certify : Il.Ast.id -> Il.Ast.rule -> t option

val prefix_source : t -> string
val focus_source : t -> string
val suffix_source : t -> string
val output_focus_source : t -> string
val value_source_typ : t -> Il.Ast.typ
val value_target_typ : t -> Il.Ast.typ
