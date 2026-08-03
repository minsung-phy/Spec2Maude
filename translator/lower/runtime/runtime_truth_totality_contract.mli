type t =
  | Total
  | Observer

val classify : name:string -> arity:int -> t option
val is_total : name:string -> arity:int -> bool
val is_observer : name:string -> arity:int -> bool
