type capture =
  { call_term : Maude_ir.term
  ; formal_var : string
  ; sort : Maude_ir.sort
  }

type phase =
  | Rule_premise
  | Seed_premise
  | Transitive

type identity =
  { phase : phase
  ; rule_index : int
  ; premise_index : int option
  }

type mode = Prove | Decide

type request =
  { helper_name : string
  ; origin : Origin.t
  ; identity : identity
  ; mode : mode
  ; source_term : Maude_ir.term
  ; captures : capture list
  ; head_var : string
  ; tail_var : string
  ; body_true : Maude_ir.rule_condition list
  ; body_false : Maude_ir.rule_condition list list
  ; result_sort : Maude_ir.sort
  ; proved : Maude_ir.term
  ; refuted : Maude_ir.term
  }

type result =
  { statements : Maude_ir.generated list
  ; true_condition : Maude_ir.rule_condition
  ; false_condition : Maude_ir.rule_condition option
  }

val materialize : request -> result
val identity_name : identity -> string
