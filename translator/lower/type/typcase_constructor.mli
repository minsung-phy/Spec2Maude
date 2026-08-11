type resolution =
  { resolved_constructor : string
  ; resolved_typ : Il.Ast.typ
  ; projection_ops : string list
  ; registry_entry : Constructor_registry.entry
  ; uniform_payload_schema : bool
  }

type lookup =
  | Found of resolution
  | Missing
  | Blocked of string
  | Ambiguous of resolution list

type payload_certificate
type ingress_certificate

val payload_certificate : resolution -> payload_certificate option

val certifies :
  payload_certificate -> constructor_op:string -> arity:int -> bool

val certifies_payloads :
  payload_certificate ->
  typs:Il.Ast.typ list ->
  sorts:Maude_ir.sort list ->
  witnesses:Maude_ir.term list ->
  bool

val certifies_payload_typs :
  payload_certificate -> Il.Ast.typ list -> bool

val ingress_certificate :
  Context.t -> constructor_op:string -> arity:int -> ingress_certificate option

val ingress_payload_guards :
  Context.t ->
  ingress_certificate ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list

val certifies_ground :
  resolution ->
  constructor_op:string ->
  Il.Ast.exp list ->
  bool

val resolve_emitted :
  Context.t -> Il.Ast.typ -> Il.Ast.mixop -> arity:int -> lookup
