type binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type introduced_binding =
  { id : string
  ; binding : binding
  ; subtype_roundtrip : Pattern_subtyping.subtype_roundtrip option
  }

type t

val empty : t
val add : t -> string -> binding -> t
val find : t -> string -> binding option
val bindings : t -> binding list
val introduce : string -> binding -> introduced_binding
val of_pattern_introduction :
  Pattern_subtyping.introduced_binding -> introduced_binding
val add_introduced : t -> introduced_binding -> t
val find_subtype_roundtrip :
  t -> string -> Pattern_subtyping.subtype_roundtrip option
val forget_subtype_roundtrips : t -> t
val bound_vars : t -> string list
val condition_bound_vars : t -> string list option
val with_condition_bound_vars : t -> string list -> t
