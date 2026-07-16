val source_echo_of_def : Il.Ast.def -> string
val constructor_of_def : Il.Ast.def -> string
val id_of_def : Il.Ast.def -> string option

type entry =
  { ordinal : int
  ; id : string option
  ; constructor : string
  ; origin : Origin.t
  ; def : Il.Ast.def
  }

type t

val of_script : Il.Ast.script -> t
val entries : t -> entry list
val find_by_id : t -> string -> entry list
