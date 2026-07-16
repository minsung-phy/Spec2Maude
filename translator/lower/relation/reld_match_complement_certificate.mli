type result =
  | Irrefutable
  | Certified of
      { failure : Maude_ir.eq_condition
      ; statements : Maude_ir.generated list
      }
  | Blocked of string

val certify :
  Constructor_registry.t ->
  origin:Origin.t ->
  helper_name:string ->
  index:int ->
  bound:string list ->
  pattern:Maude_ir.term ->
  subject:Maude_ir.term ->
  result
