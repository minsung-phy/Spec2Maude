val sanitize : string -> string
val source_slug : ?lower:bool -> string -> string
val source_id : Il.Ast.id -> string
val category_slug : Il.Ast.id -> string
val primitive_witness : string -> string
val source_mixop : Il.Ast.mixop -> string
val category_witness : Il.Ast.id -> string
val constructor_op : Il.Ast.mixop -> string
val constructor_op_in_category :
  ?record_like_single_constructor:bool -> string -> Il.Ast.mixop -> string
val constructor_op_for_typ : Il.Ast.typ -> Il.Ast.mixop -> string
val destructor_op_in_category : string -> Il.Ast.mixop -> int -> string
val destructor_op_for_typ : Il.Ast.typ -> Il.Ast.mixop -> int -> string
val wrapper_constructor_in_category : string -> string
val wrapper_constructor_for_id : Il.Ast.id -> string
val record_constructor : Il.Ast.id -> string
val definition_op : Il.Ast.id -> string
val specialized_definition_op : Il.Ast.id -> string list -> string
val relation_op : Il.Ast.id -> string
val maude_var : ?fallback:string -> string -> string
val maude_module_name : string -> string
