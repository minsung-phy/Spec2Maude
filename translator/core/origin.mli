type t =
  { region : Util.Source.region
  ; path : string list
  ; ast_constructor : string
  ; source_echo : string option
  }

val make :
  ?source_echo:string ->
  ?path:string list ->
  ast_constructor:string ->
  Util.Source.region ->
  t

val synthetic :
  ?source_echo:string ->
  ?path:string list ->
  ast_constructor:string ->
  string ->
  t

val with_child :
  ?source_echo:string ->
  t ->
  string ->
  ast_constructor:string ->
  Util.Source.region ->
  t

val path : t -> string
val source_location : t -> string
val summary : t -> string
val to_comment : t -> string
