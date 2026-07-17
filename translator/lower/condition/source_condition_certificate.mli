type t

type lookup =
  | Missing
  | Found of int * Maude_ir.eq_condition list list
  | Ambiguous

type failure =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; source_echo : string option
  }

type proof_failure

val specialize : (string * Maude_ir.term) list -> t -> t
val lookup : t list -> Maude_ir.eq_condition list -> lookup

val proof_failure :
  positive:Maude_ir.eq_condition list ->
  failure list ->
  proof_failure option

val failure :
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  ?source_echo:string ->
  unit ->
  failure

val specialize_proof_failure :
  (string * Maude_ir.term) list ->
  proof_failure ->
  proof_failure

val blockers :
  proof_failure list ->
  Maude_ir.eq_condition list ->
  failure list

val prove_if :
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  source:Il.Ast.exp ->
  emitted:Maude_ir.eq_condition list ->
  (t, Runtime_truth_totality.blocker list) result

val prove_binding :
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  source:Il.Ast.exp ->
  emitted:Maude_ir.eq_condition list ->
  (t option, Runtime_truth_totality.blocker list) result
