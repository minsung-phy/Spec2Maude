val diagnostic :
  ?suggestion:string ->
  ?source_echo:string ->
  category:Diagnostics.category ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit -> Diagnostics.t

val unsupported :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit -> Diagnostics.t

val skipped :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit -> Diagnostics.t

val obligation :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit -> Diagnostics.t

val child_origin :
  Origin.t ->
  string ->
  string ->
  Util.Source.region ->
  string option ->
  Origin.t

val source_echo_typ : Il.Ast.typ -> string option
val unsupported_carrier :
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  Il.Ast.typ ->
  Carrier_sort.typd_error ->
  Diagnostics.t
val source_echo_prem : Il.Ast.prem -> string option
val source_echo_typcase : Il.Ast.typcase -> string option
val source_echo_typfield : Il.Ast.typfield -> string option
