type binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; introduced_bindings : (string * binding) list
  ; diagnostics : Diagnostics.t list
  }

type callbacks =
  { bound_vars : string list
  ; lower_pattern :
      Local_name.t -> Origin.t -> Il.Ast.exp -> result * Local_name.t
  ; carrier_sort_of_typ : Il.Ast.typ -> Maude_ir.sort option
  ; guard_for_typ :
      Origin.t ->
      constructor:string ->
      Il.Ast.exp ->
      Maude_ir.term ->
      Il.Ast.typ ->
      Maude_ir.eq_condition list option * Diagnostics.t list
  }

val lower_direct :
  Local_name.t ->
  Context.t ->
  callbacks ->
  Origin.t ->
  Il.Ast.exp ->
  Il.Ast.exp ->
  Il.Ast.typ ->
  Il.Ast.typ ->
  result * Local_name.t

val lower_iterated :
  Local_name.t ->
  Context.t ->
  callbacks ->
  Origin.t ->
  Il.Ast.exp ->
  source_exp:Il.Ast.exp ->
  source_result:result ->
  source_term:Maude_ir.term ->
  source_typ:Il.Ast.typ ->
  target_typ:Il.Ast.typ ->
  result * Local_name.t
