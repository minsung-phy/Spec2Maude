type request =
  { source : string
  ; element_sort : Maude_ir.sort
  ; head_var : string
  ; tail_var : string
  ; witness_var : string
  }

val key : request -> string
val call : string -> Maude_ir.term -> Maude_ir.term
val result : string -> Maude_ir.term -> Maude_ir.term
val materialize :
  name:string -> Origin.t -> request -> Maude_ir.generated list
