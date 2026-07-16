type binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type t

val empty : t
val add : t -> string -> binding -> t
val find : t -> string -> binding option
val bound_vars : t -> string list
val condition_bound_vars : t -> string list option
val with_condition_bound_vars : t -> string list -> t
