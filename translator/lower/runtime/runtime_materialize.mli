type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  ; blocked_declarations : Maude_ir.generated list
  }

val run : Context.t -> result
