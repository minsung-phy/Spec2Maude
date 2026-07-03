val with_conditions :
  Expr_translate.env ->
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
  Expr_translate.env ->
  (string * Expr_translate.binding) list ->
  Expr_translate.env

val binding_is_bound :
  string list ->
  Expr_translate.binding ->
  bool

val source_id_is_bound :
  Expr_translate.env ->
  string list ->
  string ->
  bool

val unbound_direct_var :
  Expr_translate.env ->
  bound_vars:string list ->
  Il.Ast.exp ->
  Il.Ast.id option

val unbound_env_var_binding :
  Expr_translate.env ->
  bound_vars:string list ->
  Il.Ast.exp ->
  (string * Expr_translate.binding) option

val typed_var_for_exp :
  Il.Ast.id ->
  Il.Ast.exp ->
  (Maude_ir.term * Expr_translate.binding) option

val unbound_var_binding :
  Expr_translate.env ->
  bound_vars:string list ->
  Il.Ast.exp ->
  (string * Expr_translate.binding) option
