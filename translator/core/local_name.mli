type role =
  | Result
  | Pattern
  | Head
  | Tail
  | Component
  | Update
  | Value
  | Capture
  | Output
  | Witness
  | Chunk
  | Count
  | Stream
  | Byte
  | Width
  | Type
  | History

type t

val empty : t
val reserve_sources : t -> string list -> t
val reserve_phantom : t -> string -> t
val reserve_existing_many : t -> string list -> t
val fresh_typed : t -> role -> Maude_ir.sort -> Maude_ir.term * t
val source_qualified_name : t -> string -> Maude_ir.type_ref -> string
val source_qualified : t -> string -> Maude_ir.type_ref -> Maude_ir.term
val phantom_qualified_name : t -> string -> Maude_ir.type_ref -> string
val fresh_qualified_name : t -> role -> Maude_ir.type_ref -> string * t
val fresh_qualified : t -> role -> Maude_ir.type_ref -> Maude_ir.term * t
