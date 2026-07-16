val unsupported :
  ?suggestion:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  ?source_echo:string ->
  unit ->
  Diagnostics.t

val skipped :
  ?suggestion:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  ?source_echo:string ->
  unit ->
  Diagnostics.t

val source_echo_prem : Il.Ast.prem -> string

val source_echo_exp : Il.Ast.exp -> string

val origin_for_premise : Origin.t -> Il.Ast.prem -> Origin.t

val origin_for_if_conjunct : Origin.t -> string -> Il.Ast.exp -> Origin.t

val unsupported_prem :
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  string ->
  Il.Ast.prem ->
  string ->
  Premise_result.result

val unsupported_rulepr_args :
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Il.Ast.id ->
  Il.Ast.arg list ->
  Premise_result.result

val skipped_prem :
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  string ->
  Il.Ast.prem ->
  string ->
  string ->
  Premise_result.result
