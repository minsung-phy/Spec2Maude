type report

val emit : runtime:string -> semantics:string -> call_depth:int -> string -> string * report
val commands : report -> int
val checked_assertions : report -> int
val unchecked_assertions : report -> int
val runtime_assertions : report -> int
