type report

val emit : semantics:string -> steps:int -> call_depth:int -> string -> string * report
val commands : report -> int
val checked_assertions : report -> int
val runtime_assertions : report -> int
