type t =
  { declarations : Maude_ir.generated list
  ; term : Maude_ir.term
  }

val payload_sorts_complete : Constructor_registry.entry -> bool

val build :
  helper_name:string ->
  origin:Origin.t ->
  var_name:(int -> Maude_ir.sort -> string) ->
  Constructor_registry.entry ->
  t option
