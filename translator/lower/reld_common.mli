type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val empty : output
val append : output -> output -> output
