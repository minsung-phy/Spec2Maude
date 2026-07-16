type resolution =
  { resolved_constructor : string
  ; resolved_typ : Il.Ast.typ
  ; projection_ops : string list
  ; registry_entry : Constructor_registry.entry
  }

type lookup =
  | Found of resolution
  | Missing
  | Blocked of string
  | Ambiguous of resolution list

val resolve_emitted :
  Context.t -> Il.Ast.typ -> Il.Ast.mixop -> arity:int -> lookup
