type enabledness_condition_block =
  | Source_conditions of Maude_ir.eq_condition list
  | Head_domain_conditions of Maude_ir.eq_condition list

type result =
  { eq_conditions : Maude_ir.eq_condition list
  ; enabledness_condition_blocks : enabledness_condition_block list
  ; head_domain_failures : Source_condition_certificate.failure list
  ; source_condition_certificates : Source_condition_certificate.t list
  ; source_condition_failures : Source_condition_certificate.proof_failure list
  ; rule_conditions : Maude_ir.rule_condition list
  ; has_else : bool
  ; let_bound_ids : string list list
  ; env_after : Expr_env.t
  ; lhs_bound_vars : string list
  ; bound_vars_after : string list
  ; blocked_witness_source_ids : string list
  ; runtime_search_requests : Runtime_search_helper.request list
  ; runtime_truth_search_requests : Runtime_truth_search_helper.request list
  ; runtime_truth_worklist_requests : Runtime_truth_worklist_helper.request list
  ; pattern_certificate : Condition_pattern_certificate.t
  ; diagnostics : Diagnostics.t list
  }

type deferral =
  | ListN_premise_admissibility
  | Binding_membership_admissibility
  | Runtime_predicate_binding_admissibility

type complete

type outcome = private
  | Complete of complete
  | Blocked of Diagnostics.t list
  | Deferred of deferral * Diagnostics.t list

val normalize_vars : string list -> string list

val empty_with_env :
  ?lhs_bound_vars:string list ->
  ?bound_vars:string list ->
  Expr_env.t ->
  result

val empty : result
val blocked_with_env :
  bound_vars:string list ->
  Expr_env.t ->
  Diagnostics.t list ->
  result
val append : result -> result -> result
val append_complete : result -> complete -> result
val finalize_condition_bound_vars : complete -> outcome
val condition_pattern_certificate :
  ?declarations:Maude_ir.generated list ->
  Context.t ->
  complete ->
  Condition_pattern_certificate.t
val classify : result -> outcome
val blocked : Diagnostics.t list -> outcome
val deferred : deferral -> Diagnostics.t list -> outcome

val eq_conditions : complete -> Maude_ir.eq_condition list
val enabledness_condition_blocks : complete -> enabledness_condition_block list
val head_domain_failures : complete -> Source_condition_certificate.failure list
val source_condition_certificates : complete -> Source_condition_certificate.t list
val source_condition_failures :
  complete -> Source_condition_certificate.proof_failure list
val rule_conditions : complete -> Maude_ir.rule_condition list
val has_else : complete -> bool
val let_bound_ids : complete -> string list list
val env_after : complete -> Expr_env.t
val lhs_bound_vars : complete -> string list
val bound_vars_after : complete -> string list
val blocked_witness_source_ids : complete -> string list
val runtime_search_requests : complete -> Runtime_search_helper.request list
val runtime_truth_search_requests :
  complete -> Runtime_truth_search_helper.request list
val runtime_truth_worklist_requests :
  complete -> Runtime_truth_worklist_helper.request list
val pattern_certificate : complete -> Condition_pattern_certificate.t
val diagnostics : complete -> Diagnostics.t list
