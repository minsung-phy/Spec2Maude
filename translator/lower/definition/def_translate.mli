type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val translate_script : Context.t -> Il.Ast.script -> output
