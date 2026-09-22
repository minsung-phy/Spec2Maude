val term : Frontend.module_ -> string
val typecheck : semantics:string -> Frontend.module_ -> string
val instantiate : semantics:string -> Frontend.module_ -> string
val harness :
  module_name:string ->
  prefix:string ->
  export:Wasm.Ast.name ->
  Frontend.module_ ->
  string
val run :
  ?runtime:string ->
  semantics:string ->
  export:Wasm.Ast.name ->
  args:Wasm.Value.num list ->
  steps:int ->
  Frontend.module_ ->
  string

val modelcheck :
  ?runtime:string ->
  semantics:string ->
  export:Wasm.Ast.name ->
  args:Wasm.Value.num list ->
  expected:Wasm.Value.num ->
  rejected:Wasm.Value.num ->
  steps:int ->
  Frontend.module_ ->
  string
