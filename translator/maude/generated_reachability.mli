type violation =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  }

type result =
  { statements : Maude_ir.generated list
  ; violations : violation list
  }

val retain :
  blocked_declarations:Maude_ir.generated list ->
  Maude_ir.generated list ->
  result
