val sanitize : string -> string
val source_slug : ?lower:bool -> string -> string
val source_owner : string -> string
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
val projection_op : string -> int -> string
val destructor_op_for_typ : Il.Ast.typ -> Il.Ast.mixop -> int -> string
val wrapper_constructor_in_category : string -> string
val wrapper_constructor_for_id : Il.Ast.id -> string
val record_constructor : Il.Ast.id -> string
val definition_op : Il.Ast.id -> string
val builtin_definition_op : Il.Ast.id -> string
val specialized_definition_op :
  ?builtin:bool -> Il.Ast.id -> string list -> string
val relation_op : Il.Ast.id -> string
val helper_owner : Origin.t -> string
val helper_op : role:string -> owner:string -> string
val helper_ordinal : string -> int -> string
val helper_companion : role:string -> string -> string
val sort_token : string -> string
val definition_config_sort : Il.Ast.id -> string list -> string
val relation_config_sort : Il.Ast.id -> string
val helper_context_name : Origin.t -> string
val maude_var : ?fallback:string -> string -> string
val source_var : ?fallback:string -> string -> string
val maude_module_name : string -> string
