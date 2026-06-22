type status =
  | Implemented
  | Obligation

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
  ; official_semantics_source : string
  ; smoke_test : string option
  ; source_echo : string
  }

type t = entry list

val of_source_index : Analysis.Source_index.t -> t
val count : t -> int
val implemented_count : t -> int
val obligation_count : t -> int
val render_markdown : t -> string
val render_maude_interface : ?output_load:string -> t -> string
