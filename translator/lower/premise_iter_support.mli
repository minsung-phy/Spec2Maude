include module type of Premise_result

type lower_body =
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Premise_result.result

val unsupported :
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
val unsupported_prem :
  Context.t ->
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  string ->
  Il.Ast.prem ->
  string ->
  Premise_result.result

val vars_subset : string list -> string list -> bool
val conditions_bound_vars :
  string list -> Maude_ir.eq_condition list -> string list
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

val diagnostics_have_fatal : Diagnostics.t list -> bool
val flat_optional_element_typ : Il.Ast.typ -> Il.Ast.typ option
val flat_list_element_typ : Il.Ast.typ -> Il.Ast.typ option
val zip_source_descriptor :
  Il.Ast.typ -> (Helper.iter_map_source_item_shape * Il.Ast.typ) option
val app : string -> Maude_ir.term list -> Maude_ir.term
