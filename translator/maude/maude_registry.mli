type op_signature =
  { name : string
  ; args : Maude_ir.type_ref list
  ; result : Maude_ir.sort
  ; kind : Maude_ir.op_kind
  ; attrs : Maude_ir.attr list
  ; origin : Origin.t
  }

type violation =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string option
  ; source_echo : string option
  }

type t

val build : Maude_ir.generated list -> t * violation list
val validate_module : Maude_ir.module_ -> violation list
val diagnostics : profile:string -> violation list -> Diagnostics.t list
val has_sort : t -> string -> bool
val has_op : t -> name:string -> arity:int -> bool
val find_ops : t -> name:string -> op_signature list
