type plan

type field_plan =
  | Append
  | Compose_optional
  | Compose_record of plan

type definition
type conflict
type constructor
type t

type registration =
  | Fresh
  | Duplicate
  | Conflict of conflict

type helper_status =
  | Helper_emitted
  | Helper_missing
  | Helper_unavailable of Il.Ast.id list
  | Helper_incompatible

val create : unit -> t
val copy : t -> t
val replace : target:t -> source:t -> unit

val plan : Il.Ast.id -> (Il.Ast.atom * field_plan) list -> plan
val plan_id : plan -> Il.Ast.id
val plan_fields : plan -> (Il.Ast.atom * field_plan) list

val definition :
  origin:Origin.t ->
  id:Il.Ast.id ->
  fields:(Il.Ast.atom * Maude_ir.sort) list ->
  composition:plan option ->
  surface:Maude_ir.statement_node list ->
  definition

val register : t -> definition -> registration
val missing_dependencies : t -> plan -> Il.Ast.id list
val note_helper_unavailable : t -> plan -> Il.Ast.id list -> unit
val note_helper_emitted : t -> plan -> unit
val helper_status : t -> plan -> helper_status
val describe_conflict : conflict -> string

val constructors : t -> constructor list
val constructor_name : constructor -> string
val constructor_payload_sorts : constructor -> Maude_ir.sort list
