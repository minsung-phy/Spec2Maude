type binding = Pattern_subtyping.binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type result = Pattern_subtyping.result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; introduced_bindings : (string * binding) list
  ; diagnostics : Diagnostics.t list
  }

type callbacks =
  { find_var : string -> binding option
  ; bound_vars : string list
  ; lower_guard_value : Origin.t -> Il.Ast.exp -> result
  ; carrier_sort_of_typ : Il.Ast.typ -> Maude_ir.sort option
  ; is_nat_typ : Il.Ast.typ -> bool
  ; witness_of_typ :
      constructor:string ->
      Origin.t ->
      Il.Ast.typ ->
      Maude_ir.term option * Maude_ir.eq_condition list * Diagnostics.t list
  ; case_constructor :
      Origin.t ->
      Il.Ast.exp ->
      Il.Ast.mixop ->
      int ->
      string option * Diagnostics.t list
  }

val lower_with_names :
  Local_name.t ->
  Context.t -> callbacks -> Origin.t -> Il.Ast.exp -> result * Local_name.t
