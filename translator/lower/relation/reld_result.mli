type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val empty : output
val append : output -> output -> output

val unsupported :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit ->
  Diagnostics.t

val skipped :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit ->
  Diagnostics.t

val one_diagnostic : Diagnostics.t -> output
val has_fatal : Diagnostics.t list -> bool
val dedup_conditions : Maude_ir.eq_condition list -> Maude_ir.eq_condition list
val dedup_rule_conditions : Maude_ir.rule_condition list -> Maude_ir.rule_condition list
val dedup_generated : Maude_ir.generated list -> Maude_ir.generated list
