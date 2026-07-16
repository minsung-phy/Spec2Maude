val analyze :
  profile:string ->
  Builtin_backend.t ->
  Analysis.Function_graph.t ->
  Analysis.Source_index.t ->
  Maude_ir.generated list ->
  Constructor_registry.t ->
  Builtin_registry.t ->
  Builtin_registry.t * string option * Diagnostics.t list
