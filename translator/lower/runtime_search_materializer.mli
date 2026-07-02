type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_search_helper.request
  }

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val materialize : Context.t -> item list -> result
