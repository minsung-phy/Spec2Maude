val term : Frontend.module_ -> string
val typecheck : semantics:string -> Frontend.module_ -> string
val instantiate : semantics:string -> Frontend.module_ -> string
val run :
  semantics:string ->
  export:Wasm.Ast.name ->
  args:Wasm.Value.num list ->
  steps:int ->
  Frontend.module_ ->
  string
