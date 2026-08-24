type t

val atom : string -> t
val app : string -> t list -> t
val seq : t list -> t
val to_string : t -> string
val pp : Format.formatter -> t -> unit
