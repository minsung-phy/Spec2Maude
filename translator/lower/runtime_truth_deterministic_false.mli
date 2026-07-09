type support =
  | Not_deterministic
  | Supported
  | Blocked of string list

type materialization =
  | Not_deterministic_materialization
  | Materialized of
      { statements : Maude_ir.generated list
      ; diagnostics : Diagnostics.t list
      }
  | Materialization_blocked of
      { diagnostics : Diagnostics.t list
      ; blockers : string list
      }

val check :
  Context.t ->
  rel_id:string ->
  exp:Il.Ast.exp ->
  support

val materialize :
  Context.t ->
  helper_name:string ->
  origin:Origin.t ->
  env:Expr_translate.env ->
  label:string ->
  lhs:Maude_ir.term ->
  rhs:Maude_ir.term ->
  rel_id:Il.Ast.id ->
  exp:Il.Ast.exp ->
  materialization
