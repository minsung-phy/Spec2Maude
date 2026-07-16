type status = Implemented | Obligation
type activity = Active | Dormant

type requirement_source =
  | Hint_builtin
  | Declaration_only
  | Equational_view
  | Relation_surface

type dec_signature =
  { params : string list
  ; result : string
  ; source_location : string
  ; origin : Origin.t
  ; source_clauses : int
  ; has_static_params : bool
  }

type entry =
  { source_id : string
  ; hint_location : string
  ; hint_origin : Origin.t
  ; generated_op_stem : string
  ; signature : dec_signature option
  ; status : status
  ; source_echo : string
  ; requirement_source : requirement_source
  ; activity : activity
  ; backend_requirement : Builtin_backend.requirement option
  ; backend_issue : string option
  }

type t

val of_source_index :
  ?backend:Builtin_backend.t -> Analysis.Source_index.t -> t
val entries : t -> entry list
val find : t -> string -> entry option
val is_hint_builtin : t -> string -> bool
val definition_op : t -> Il.Ast.id -> string
val declaration_is_partial : t -> string -> bool
val with_entries : t -> entry list -> t
