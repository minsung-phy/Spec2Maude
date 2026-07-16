type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let empty = { statements = []; diagnostics = [] }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let with_diagnostics diagnostics =
  { empty with diagnostics }
