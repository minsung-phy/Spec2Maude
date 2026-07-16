type totality = Total | Partial
type demand = Direct | Indirect
type scope = Global | Scoped

type requirement
type representation
type t

val load : unit -> t
val name : t -> string
val description : t -> string
val source : t -> string
val revision : t -> string
val module_name : t -> string
val abi : t -> int
val contract_path : t -> string
val smoke_fixture : t -> string
val find : t -> string -> requirement option
val requirements : t -> requirement list
val requirement_key : requirement -> string
val public_op : requirement -> string
val totality : requirement -> totality
val demand : requirement -> demand
val dependencies : requirement -> string list
val representations : requirement -> string list
val representation_requirements : t -> representation list
val representation : t -> string -> representation option
val representation_key : representation -> string
val representation_scope : representation -> scope
val representation_category : representation -> string
val representation_arity : representation -> int
val representation_payload_sort : representation -> string
val representation_constructor : representation -> string
val representation_witness : representation -> string option
val render : ?output_load:string -> t -> string
