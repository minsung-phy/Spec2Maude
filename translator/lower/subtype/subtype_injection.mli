type case
type t

val make_case :
  source_op:string ->
  target_op:string ->
  payload_sorts:Maude_ir.sort list ->
  case

val make :
  source_category:string ->
  target_category:string ->
  cases:case list ->
  t

val source_category : t -> string
val target_category : t -> string
val cases : t -> case list
val source_op : case -> string
val target_op : case -> string
val payload_sorts : case -> Maude_ir.sort list
val forward_name : t -> string
val projection_name : forward:string -> string
val sequence_projection_name : forward:string -> string
val key : t -> string
