type t

val empty : t
val imported : t
val source : Context.t -> t
val generated : Maude_ir.generated list -> t
val union : t -> t -> t
val admits : t -> string -> int -> bool
val is_pattern : t -> Maude_ir.term -> bool
