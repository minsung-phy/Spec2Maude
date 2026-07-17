type blocker =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; source_echo : string option
  }

val diagnostic : Context.t -> blocker -> Diagnostics.t

val certified_binding_pattern :
  Context.t -> string list -> Il.Ast.exp -> bool

val source_total :
  ?facts:Runtime_truth_successor_domain.total_fact list ->
  Context.t -> bound:string list -> Origin.t -> Il.Ast.exp -> bool

(** [source_zero_or_one] recognizes an equation-backed, single-clause DecD
    call whose arguments are total.  The call itself may be undefined.  A
    caller may therefore use it only through a constructor result match, with
    the unmatched case denoting no result. *)
val source_zero_or_one :
  Context.t -> bound:string list -> Origin.t -> Il.Ast.exp -> bool

val source_condition_blocker :
  Origin.t -> Il.Ast.exp -> reason:string -> blocker

val false_conditions :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.cmpop ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  ((Maude_ir.eq_condition list * Diagnostics.t list), blocker list) result

val false_condition_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.cmpop ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  ((Maude_ir.eq_condition list list * Diagnostics.t list), blocker list) result

val source_equality_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  ((Maude_ir.term * Maude_ir.term * Maude_ir.eq_condition list *
    Maude_ir.eq_condition list list * Diagnostics.t list), blocker list) result

val source_definedness_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  ((Maude_ir.eq_condition list * Maude_ir.eq_condition list list *
    Diagnostics.t list), blocker list) result

val source_boolean_alternatives :
  ?bound_vars:string list ->
  Context.t ->
  Expr_env.t ->
  Origin.t ->
  Il.Ast.exp ->
  ((Maude_ir.eq_condition list * Maude_ir.eq_condition list list *
    Diagnostics.t list), blocker list) result
