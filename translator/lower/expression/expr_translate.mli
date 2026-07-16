type result = Expr_result.result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type binding = Expr_env.binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type pattern_result = Expr_result.pattern_result =
  { pattern_term : Maude_ir.term option
  ; pattern_guards : Maude_ir.eq_condition list
  ; introduced_bindings : (string * binding) list
  ; pattern_diagnostics : Diagnostics.t list
  }

type env = Expr_env.t
val carrier_sort_of_typ : Il.Ast.typ -> Maude_ir.sort option
val typecheck_conditions_for_typ :
  Il.Ast.typ ->
  Maude_ir.sort ->
  Maude_ir.term ->
  Maude_ir.term ->
  Maude_ir.eq_condition list
val lower_value : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_numeric_guard_value : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_pattern_with_bindings_named :
  Local_name.t ->
  Context.t -> env -> Origin.t -> Il.Ast.exp -> pattern_result * Local_name.t
val lower_bool_condition : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_sequence : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_type_witness :
  Context.t -> env -> Origin.t -> constructor:string -> Il.Ast.typ -> result
