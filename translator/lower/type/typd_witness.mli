val terms_of_args :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  Il.Ast.arg list ->
  Maude_ir.term list option * Diagnostics.t list

val of_typ :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  constructor:string ->
  Il.Ast.typ ->
  Maude_ir.term option * Diagnostics.t list
