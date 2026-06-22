type category =
  | Unsupported
  | Skipped
  | Obligation
  | PreludeGap

type severity =
  | Info
  | Warning
  | Fatal

type t = private
  { category : category
  ; severity : severity
  ; origin : Origin.t
  ; constructor : string
  ; enclosing : string list
  ; profile : string
  ; reason : string
  ; suggestion : string option
  ; source_echo : string option
  }

val string_of_category : category -> string
val string_of_severity : severity -> string
val default_severity : category -> severity

val make :
  ?severity:severity ->
  ?suggestion:string ->
  ?source_echo:string ->
  category:category ->
  origin:Origin.t ->
  constructor:string ->
  enclosing:string list ->
  profile:string ->
  reason:string ->
  unit ->
  t

val is_fatal : t -> bool
val render : t -> string
val render_all : t list -> string
val dedup : t list -> t list
val count_by : (t -> bool) -> t list -> int
val summary : t list -> string
