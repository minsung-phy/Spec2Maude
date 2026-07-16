val source_echo_exp : Il.Ast.exp -> string

val unsupported :
  ?suggestion:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  ?source_echo:string ->
  ?deferral:Diagnostics.deferral ->
  unit ->
  Diagnostics.t

val prelude_gap :
  ?suggestion:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  ?source_echo:string ->
  unit ->
  Diagnostics.t

val unsupported_witness :
  Context.t -> Origin.t -> string -> string -> string -> Diagnostics.t
val unsupported_exp :
  Context.t -> Origin.t -> string -> Il.Ast.exp -> string -> Expr_result.result
val sequence_sort_diagnostic :
  Context.t -> Origin.t -> Il.Ast.exp -> Diagnostics.t
