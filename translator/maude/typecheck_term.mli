val typecheck : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val typecheck_seq : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val typecheck_opt_seq : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val typecheck_seq_opt : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val typecheck_nested_seq : Maude_ir.term -> Maude_ir.term -> Maude_ir.term
val typecheck_for_sort :
  Maude_ir.sort -> Maude_ir.term -> Maude_ir.term -> Maude_ir.term
