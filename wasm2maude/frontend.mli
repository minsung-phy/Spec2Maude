type module_ = {
  source : string;
  ast : Wasm.Ast.module_;
  custom : Wasm.Custom.section list;
}

type invocation_error =
  | Missing_export
  | Non_function_export
  | Unresolved_function_type
  | Wrong_arity
  | Wrong_argument_type of int

val load : string -> module_
val of_definition : string -> Wasm.Script.definition -> module_
val text : name:string -> string -> module_
val binary : name:string -> string -> module_
val import_count : module_ -> int
val export_type : module_ -> Wasm.Ast.name -> Wasm.Types.externtype option
val validate_invocation :
  module_ ->
  Wasm.Ast.name ->
  Wasm.Types.valtype list ->
  (unit, invocation_error) result
