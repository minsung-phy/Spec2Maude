type worklist
type scope
type request

val create :
  helper_name:string ->
  identity:Runtime_truth_worklist_indexed.identity ->
  env:Expr_env.t ->
  terms:Maude_ir.term list ->
  sorts:Maude_ir.sort list ->
  history:Maude_ir.term ->
  worklist * scope

val scope_formals : scope -> Maude_ir.term list
val scope_witness : scope -> Maude_ir.term
val scope_current : scope -> Maude_ir.term

val request :
  worklist:worklist ->
  origin:Origin.t ->
  mode:Runtime_truth_worklist_indexed.mode ->
  candidates:Maude_ir.term list ->
  certified_successors:Maude_ir.term list ->
  start:Maude_ir.term ->
  target:Maude_ir.term ->
  domain_true:Maude_ir.rule_condition list ->
  domain_false:Maude_ir.rule_condition list list ->
  direct_true:Maude_ir.rule_condition ->
  direct_false:Maude_ir.rule_condition ->
  result_sort:Maude_ir.sort ->
  proved:Maude_ir.term ->
  refuted:Maude_ir.term ->
  request

val materialize : request -> Runtime_truth_worklist_indexed.result
