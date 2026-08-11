type binding = Pattern_subtyping.binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type introduced_binding = Pattern_subtyping.introduced_binding =
  { id : string
  ; binding : binding
  ; subtype_roundtrip : Pattern_subtyping.subtype_roundtrip option
  }

type result = Pattern_subtyping.result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; introduced_bindings : introduced_binding list
  ; diagnostics : Diagnostics.t list
  }

type constructor_case =
  { operator : string
  ; payload_certificate : Typcase_constructor.payload_certificate option
  }

type guard_policy =
  (* Preserve every pattern guard. *)
  | Full
  (* Preserve the enclosing constructor guard and discharge only its exact
     certified payload checks. *)
  | Whole_constructor
  (* The validated execution ingress discharges certified constructor guards. *)
  | Validated_ingress

type callbacks =
  { find_var : string -> binding option
  ; bound_vars : string list
  ; guard_policy : guard_policy
  ; typed_subject : bool
  ; typed_payload : bool
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
      constructor_case option * Diagnostics.t list
  }

val lower_with_names :
  Local_name.t ->
  Context.t -> callbacks -> Origin.t -> Il.Ast.exp -> result * Local_name.t
