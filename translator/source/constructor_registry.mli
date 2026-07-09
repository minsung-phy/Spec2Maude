type status =
  | Emitted
  | Skipped
  | Unsupported

type entry =
  { source_category : string
  ; declaring_category : string
  ; static_args_key : string option
  ; mixop : Il.Ast.mixop
  ; arity : int
  ; constructor_op : string
  ; projection_ops : string list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; origin : Origin.t
  ; enclosing : string list
  ; status : status
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

type t

val create : unit -> t
val register : t -> entry -> unit
val register_inclusion : t -> inclusion -> unit
val entries : t -> entry list
val inclusions : t -> inclusion list
val lookup :
  t ->
  source_category:string ->
  static_args_key:string option ->
  mixop:Il.Ast.mixop ->
  arity:int ->
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
val diagnostics : profile:string -> t -> Diagnostics.t list
