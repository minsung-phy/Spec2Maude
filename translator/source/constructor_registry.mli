type status =
  | Emitted
  | Skipped
  | Unsupported

type construction_domain =
  | Total_constructor
  | Certified_representation_constructor
  | Length_guarded_representation_constructor of
      { payload_index : int
      ; closed_bound : Il.Ast.exp
      ; guard_origin : Origin.t
      }
  | Guarded_constructor of string

type payload_label =
  | Source_category of string
  | Primitive_type of string
  | Structural_payload

type entry =
  { source_category : string
  ; declaring_category : string
  ; static_args_key : string option
  ; mixop : Il.Ast.mixop
  ; arity : int
  ; constructor_op : string
  ; projection_ops : string list
  ; payload_labels : payload_label list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; origin : Origin.t
  ; enclosing : string list
  ; status : status
  ; construction_domain : construction_domain
  }

type lookup =
  | Found of entry
  | Missing
  | Ambiguous of entry list

type projection_lookup =
  | Projection_found of entry
  | Projection_missing
  | Projection_ambiguous of entry list

type inclusion =
  { parent_category : string
  ; parent_static_args_key : string option
  ; child_category : string
  ; child_static_args_key : string option
  ; origin : Origin.t
  ; reason : string
  }

type family_coverage =
  | Closed of entry list
  | Open of string list

type t

type registration =
  | Registered
  | Already_registered
  | Rejected_after_resolution

val create : unit -> t
val copy : t -> t
val replace : target:t -> source:t -> unit
val register : t -> entry -> unit
val register_checked : t -> entry -> registration
val resolve_surfaces : t -> unit
val register_inclusion : t -> inclusion -> unit
val note_source_case :
  t ->
  source_category:string ->
  static_args_key:string option ->
  Origin.t ->
  unit
val entries : t -> entry list
val is_constructor_op : t -> string -> bool
val inclusions : t -> inclusion list
val visible_emitted_entries :
  t ->
  source_category:string ->
  static_args_key:string option ->
  entry list
val family_coverage :
  t ->
  source_category:string ->
  static_args_key:string option ->
  family_coverage
val lookup :
  t ->
  source_category:string ->
  static_args_key:string option ->
  mixop:Il.Ast.mixop ->
  arity:int ->
  lookup
val lookup_at_origin :
  t ->
  source_category:string ->
  static_args_key:string option ->
  mixop:Il.Ast.mixop ->
  arity:int ->
  origin:Origin.t ->
  lookup
val lookup_visible :
  t ->
  source_category:string ->
  static_args_key:string option ->
  mixop:Il.Ast.mixop ->
  arity:int ->
  lookup
val lookup_emitted :
  t ->
  source_category:string ->
  static_args_key:string option ->
  mixop:Il.Ast.mixop ->
  arity:int ->
  lookup
val lookup_direct_emitted :
  t ->
  source_category:string ->
  static_args_key:string option ->
  mixop:Il.Ast.mixop ->
  arity:int ->
  lookup
val category_includes :
  t ->
  parent_category:string ->
  child_category:string ->
  bool
val lookup_unary_projection :
  t ->
  projection_op:string ->
  projection_lookup
val has_wrapper :
  t ->
  source_category:string ->
  static_args_key:string option ->
  bool
val status_to_string : status -> string
val construction_domain_to_string : construction_domain -> string
val diagnostics : profile:string -> t -> Diagnostics.t list
