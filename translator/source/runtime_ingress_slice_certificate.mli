type t
type blocker

type discharge =
  { retained : Il.Ast.prem list
  ; certificates : t list
  ; blockers : blocker list
  }

val certify :
  Context.t ->
  definition_id:string ->
  clause_index:int ->
  lhs_args:Il.Ast.arg list ->
  rhs:Il.Ast.exp ->
  Il.Ast.prem list ->
  discharge

val first_index : t -> int
val last_index : t -> int
val introduced_source_ids : t -> string list
val source_echo : t -> string
val origin : t -> Origin.t
val contract_origin : t -> string option
val blocker_origin : blocker -> Origin.t
val blocker_reason : blocker -> string
val blocker_suggestion : blocker -> string
val blocker_source_echo : blocker -> string
