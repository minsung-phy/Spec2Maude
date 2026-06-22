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

let count = List.length

let implemented_count entries =
  entries
  |> List.filter (fun entry -> entry.status = Implemented)
  |> List.length

let obligation_count entries =
  entries
  |> List.filter (fun entry -> entry.status = Obligation)
  |> List.length

let status_to_string = function
  | Implemented -> "IMPLEMENTED"
  | Obligation -> "OBLIGATION"
