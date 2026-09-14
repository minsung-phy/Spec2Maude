val render :
  semantics:string ->
  steps:int ->
  commands:(string * Maude_term.t) list ->
  host_store:string ->
  host_instances:string ->
  host_functions:string ->
  string
