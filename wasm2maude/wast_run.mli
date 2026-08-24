type report

val emit : semantics:string -> steps:int -> call_depth:int -> string -> string * report
val checked : report -> int
val runtime_assertions : report -> int
