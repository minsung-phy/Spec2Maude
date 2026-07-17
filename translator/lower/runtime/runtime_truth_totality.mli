type blocker =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; source_echo : string option
  }

type definedness = private
  { domains : Maude_ir.term list
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

val blocker : Origin.t -> Il.Ast.exp -> string -> string -> blocker
val diagnostic : Context.t -> blocker -> Diagnostics.t

val certified_binding_pattern :
  Context.t -> string list -> Il.Ast.exp -> bool

val check :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  (unit, blocker list) result

val source_total :
  ?facts:Runtime_truth_successor_domain.total_fact list ->
  Context.t -> bound:string list -> Origin.t -> Il.Ast.exp -> bool

(** [source_zero_or_one] recognizes an equation-backed, single-clause DecD
    call whose arguments are total.  The call itself may be undefined.  A
    caller may therefore use it only through a constructor result match, with
    the unmatched case denoting no result. *)
val source_zero_or_one :
  Context.t -> bound:string list -> Origin.t -> Il.Ast.exp -> bool

val definedness :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  (definedness, blocker list) result
