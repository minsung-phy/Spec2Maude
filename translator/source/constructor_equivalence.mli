type construction_domain =
  | Total_constructor
  | Certified_representation_constructor
  | Length_guarded_representation_constructor of
      { payload_index : int
      ; closed_bound : Il.Ast.exp
      ; guard_origin : Origin.t
      }
  | Guarded_constructor of string

type source_case =
  { payload_typ : Il.Ast.typ
  ; case_binds : Il.Ast.quant list
  ; case_prems : Il.Ast.prem list
  ; instance_binds : Il.Ast.quant list
  ; instance_args : Il.Ast.arg list
  ; static_args_key : string option
  ; construction_domain : construction_domain
  }

type entry =
  { source_category : string
  ; static_args_key : string option
  ; mixop : Il.Ast.mixop
  ; arity : int
  ; payload_typs : Il.Ast.typ list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; source_case : source_case option
  ; origin : Origin.t
  ; emitted : bool
  }

type t

val analyze : entries:entry list -> t
val canonical_entry : t -> entry -> entry option
val equivalent : t -> entry -> entry -> bool
val shared : t -> entry -> bool
