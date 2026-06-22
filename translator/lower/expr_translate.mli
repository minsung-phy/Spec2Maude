type result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type pattern_result =
  { pattern_term : Maude_ir.term option
  ; pattern_guards : Maude_ir.eq_condition list
  ; introduced_bindings : (string * binding) list
  ; pattern_diagnostics : Diagnostics.t list
  }

type env

val empty_env : env
val add_var : env -> string -> binding -> env
val find_var : env -> string -> binding option
val env_bound_vars : env -> string list
val with_condition_bound_vars : env -> string list -> env
val carrier_sort_of_typ : Il.Ast.typ -> Maude_ir.sort option
val type_ref_of_sort : Maude_ir.sort -> Maude_ir.type_ref
val lower_value : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_numeric_guard_value : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_pattern : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_pattern_with_bindings :
  Context.t -> env -> Origin.t -> Il.Ast.exp -> pattern_result
val lower_bool_condition : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
val lower_sequence : Context.t -> env -> Origin.t -> Il.Ast.exp -> result
