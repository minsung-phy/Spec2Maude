type status
type report

val run :
  semantics:string ->
  maude:string ->
  timeout:float ->
  steps:int ->
  call_depth:int ->
  ?progress:(
    completed:int ->
    total:int ->
    source:string ->
    status:string ->
    seconds:float ->
    unit) ->
  ?log_dir:string ->
  string ->
  report

val to_tsv : report -> string
val summary : report -> (string * int) list
val successful : report -> bool
