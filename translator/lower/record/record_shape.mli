type t =
  { id : Il.Ast.id
  ; fields : Il.Ast.typfield list
  }

type concatenable =
  | Sequence
  | Optional
  | Record of t

type error

val of_typ : Context.t -> Il.Ast.typ -> (t, error) result
val concatenable : Context.t -> Il.Ast.typ -> (concatenable, error) result
val composition : Context.t -> t -> (Record_certificate.plan, error) result
val error_path : error -> Il.Ast.atom list
val match_fields : t -> Il.Ast.expfield list -> ((Il.Ast.typfield * Il.Ast.expfield) list, error) result
val describe_error : error -> string
