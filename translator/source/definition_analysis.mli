type param_kind =
  | Runtime_exp
  | Static_typ
  | Static_def
  | Static_gram

type definition =
  { id : string
  ; origin : Origin.t
  ; params : param_kind list
  ; result : Il.Ast.typ
  ; clause_count : int
  ; partial : bool
  }

type definition_identity =
  { def_id : string
  ; specialization_key : string list
  }

type emitted_definition =
  { identity : definition_identity
  ; source_id : string
  ; op_name : string
  ; result : Il.Ast.typ
  ; rewrite_backed : bool
  }

type inverse_status =
  | No_inverse
  | Valid_inverse of string
  | Invalid_inverse of
      { reason : string
      ; hint_origin : Origin.t
      }

type static_typ_binding =
  { param_id : string
  ; typ : Il.Ast.typ
  ; key : string
  }

type static_def_binding =
  { param_id : string
  ; target_id : string
  ; key : string
  }

type specialization =
  { def_id : string
  ; key_components : string list
  ; static_typs : static_typ_binding list
  ; static_defs : static_def_binding list
  ; origin : Origin.t
  }

type call_resolution =
  | Plain_call
  | Specialized_call of specialization
  | Unsupported_call of string
  | Prelude_gap_call of string

type t

val build : Source_index.t -> t
val diagnostics : profile:string -> t -> Diagnostics.t list
val definitions : t -> definition list
val find_definition : t -> string -> definition option
val definition_inverse : t -> string -> string option
val definition_is_partial : t -> string -> bool
val definition_is_rewrite_backed : t -> string -> bool
val plain_identity : string -> definition_identity
val identity_of_specialization : specialization -> definition_identity
val identity_is_rewrite_backed : t -> definition_identity -> bool
val definition_is_runtime_entry : t -> string -> bool
val emitted_definition : t -> definition_identity -> emitted_definition option
val definition_inverse_status : t -> string -> inverse_status
val specializations_for : t -> string -> specialization list
val has_specialization : t -> specialization -> bool
val resolve_call :
  t ->
  static_typ_env:(string * Il.Ast.typ) list ->
  static_def_env:(string * string) list ->
  origin:Origin.t ->
  Il.Ast.id ->
  Il.Ast.arg list ->
  call_resolution
val relation_analysis : t -> Relation_analysis.t
