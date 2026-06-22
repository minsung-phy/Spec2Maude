type result =
  { module_ : Maude_ir.module_
  ; diagnostics : Diagnostics.t list
  ; source_index : Analysis.Source_index.t
  ; maude_registry : Maude_registry.t
  ; builtin_registry : Builtin_registry.t
  }

val translate : ?profile:Context.profile -> Il.Ast.script -> result
val emit : result -> string
val emit_builtins : ?output_load:string -> result -> string
val emit_builtin_report : result -> string
val has_fatal_diagnostics : result -> bool
