type result =
  { module_ : Maude_ir.module_
  ; diagnostics : Diagnostics.t list
  ; source_index : Analysis.Source_index.t
  ; maude_registry : Maude_registry.t
  ; builtin_backend : Builtin_backend.t
  ; builtin_registry : Builtin_registry.t
  }

val translate :
  ?runtime_ingress_specs:Runtime_ingress_contract.spec list ->
  Il.Ast.script ->
  result
val retain_atomic_statements :
  blocked_declarations:Maude_ir.generated list ->
  Maude_ir.generated list ->
  Maude_ir.generated list
val emit : result -> string
val emit_partial : result -> string
val emit_builtins : ?output_load:string -> result -> string
val emit_partial_builtins : ?output_load:string -> result -> string
val emit_builtin_report : result -> string
val has_fatal_diagnostics : result -> bool
