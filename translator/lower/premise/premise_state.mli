val with_conditions :
  ?pattern_certificate:Condition_pattern_certificate.t ->
  Context.t ->
  Expr_env.t ->
  string list ->
  Maude_ir.eq_condition list ->
  Diagnostics.t list ->
  Premise_result.result

val take_match_binding :
  string ->
  Maude_ir.eq_condition list ->
  (Maude_ir.term * Maude_ir.eq_condition list) option

val add_introduced_bindings :
  ?ids:string list ->
  Expr_env.t ->
  (string * Expr_env.binding) list ->
  Expr_env.t

val binding_is_bound :
  string list ->
  Expr_env.binding ->
  bool

val source_id_is_bound :
  Expr_env.t ->
  string list ->
  string ->
  bool

val unbound_direct_var :
  Expr_env.t ->
  bound_vars:string list ->
  Il.Ast.exp ->
  Il.Ast.id option

val unbound_env_var_binding :
  Expr_env.t ->
  bound_vars:string list ->
  Il.Ast.exp ->
  (string * Expr_env.binding) option

val typed_var_for_exp :
  Local_name.t ->
  Il.Ast.id ->
  Il.Ast.exp ->
  (Maude_ir.term * Expr_env.binding) option

val unbound_var_binding :
  Local_name.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Il.Ast.exp ->
  (string * Expr_env.binding) option
