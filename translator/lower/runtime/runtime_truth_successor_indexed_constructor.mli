type capture =
  { call_term : Maude_ir.term
  ; formal_var : string
  ; sort : Maude_ir.sort
  }

type request =
  { helper_name : string
  ; origin : Origin.t
  ; index : int
  ; source_term : Maude_ir.term
  ; captures : capture list
  ; index_var : string
  ; head_var : string
  ; tail_var : string
  ; successor_term : Maude_ir.term
  ; successor_guards : Maude_ir.eq_condition list
  }

type result =
  { term : Maude_ir.term
  ; statements : Maude_ir.generated list
  }

val materialize : request -> result
