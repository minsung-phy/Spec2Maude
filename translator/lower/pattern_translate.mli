type form =
  | Var_pattern
  | Literal_pattern
  | Constructor_pattern
  | Sequence_pattern
  | Optional_pattern
  | Coercion_pattern
  | Tuple_pattern
  | Record_pattern
  | Non_pattern of string

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
  { find_var : string -> binding option
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

val classify : Il.Ast.exp -> form
val form_name : form -> string
val lower : Context.t -> callbacks -> Origin.t -> Il.Ast.exp -> result
