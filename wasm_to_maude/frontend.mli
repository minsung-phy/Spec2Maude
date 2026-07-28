type module_ = {
  source : string;
  ast : Wasm.Ast.module_;
  custom : Wasm.Custom.section list;
}

val load : string -> module_
val of_definition : string -> Wasm.Script.definition -> module_
val text : name:string -> string -> module_
val binary : name:string -> string -> module_
val import_count : module_ -> int
