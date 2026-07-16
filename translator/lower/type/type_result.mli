type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val empty : result
val append : result -> result -> result
val with_diagnostics : Diagnostics.t list -> result
