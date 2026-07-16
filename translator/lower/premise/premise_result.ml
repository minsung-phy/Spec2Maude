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

type complete = result

type outcome =
  | Complete of complete
  | Blocked of Diagnostics.t list
  | Deferred of deferral * Diagnostics.t list

let normalize_vars vars =
  vars |> List.sort_uniq String.compare

let empty_with_env ?lhs_bound_vars ?(bound_vars = []) env =
  let lhs_bound_vars =
    Option.value ~default:bound_vars lhs_bound_vars |> normalize_vars
  in
  { eq_conditions = []
  ; enabledness_condition_blocks = []
  ; head_domain_failures = []
  ; source_condition_certificates = []
  ; source_condition_failures = []
  ; rule_conditions = []
  ; has_else = false
  ; let_bound_ids = []
  ; env_after = env
  ; lhs_bound_vars
  ; bound_vars_after = normalize_vars bound_vars
  ; blocked_witness_source_ids = []
  ; runtime_search_requests = []
  ; runtime_truth_search_requests = []
  ; runtime_truth_worklist_requests = []
  ; pattern_certificate = Condition_pattern_certificate.empty
  ; diagnostics = []
  }

let empty = empty_with_env Expr_env.empty

let blocked_with_env ~bound_vars env diagnostics =
  { (empty_with_env ~bound_vars env) with diagnostics }

let append left right =
  { eq_conditions = left.eq_conditions @ right.eq_conditions
  ; enabledness_condition_blocks =
      left.enabledness_condition_blocks @ right.enabledness_condition_blocks
  ; head_domain_failures =
      left.head_domain_failures @ right.head_domain_failures
  ; source_condition_certificates =
      left.source_condition_certificates @ right.source_condition_certificates
  ; source_condition_failures =
      left.source_condition_failures @ right.source_condition_failures
  ; rule_conditions = left.rule_conditions @ right.rule_conditions
  ; has_else = left.has_else || right.has_else
  ; let_bound_ids = left.let_bound_ids @ right.let_bound_ids
  ; env_after = right.env_after
  ; lhs_bound_vars = left.lhs_bound_vars
  ; bound_vars_after = right.bound_vars_after
  ; blocked_witness_source_ids =
      normalize_vars
        (left.blocked_witness_source_ids @ right.blocked_witness_source_ids)
  ; runtime_search_requests =
      left.runtime_search_requests @ right.runtime_search_requests
  ; runtime_truth_search_requests =
      left.runtime_truth_search_requests @ right.runtime_truth_search_requests
  ; runtime_truth_worklist_requests =
      left.runtime_truth_worklist_requests @ right.runtime_truth_worklist_requests
  ; pattern_certificate =
      Condition_pattern_certificate.union
        left.pattern_certificate right.pattern_certificate
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let append_complete left (right : complete) = append left right

let condition_pattern_certificate ?(declarations = []) ctx (result : complete) =
  Condition_pattern_certificate.union
    (Condition_closure.source_constructor_certificate ctx)
    (Condition_pattern_certificate.union
       result.pattern_certificate
       (Condition_pattern_certificate.generated declarations))

let blocked diagnostics = Blocked diagnostics
let deferred deferral diagnostics = Deferred (deferral, diagnostics)

let classify result =
  let deferred kind =
    result.diagnostics
    |> List.exists (fun diagnostic ->
      Diagnostics.is_fatal diagnostic
      && diagnostic.Diagnostics.deferral = Some kind)
  in
  if deferred Diagnostics.ListN_premise_admissibility then
    Deferred (ListN_premise_admissibility, result.diagnostics)
  else if deferred Diagnostics.Binding_membership_admissibility then
    Deferred (Binding_membership_admissibility, result.diagnostics)
  else if deferred Diagnostics.Runtime_predicate_binding_admissibility then
    Deferred (Runtime_predicate_binding_admissibility, result.diagnostics)
  else if List.exists Diagnostics.is_fatal result.diagnostics then
    Blocked result.diagnostics
  else
    Complete result

let finalize_condition_bound_vars (result : complete) =
  classify
    { result with
      env_after =
        Expr_env.with_condition_bound_vars
          result.env_after result.bound_vars_after
    }

let eq_conditions (result : complete) = result.eq_conditions
let enabledness_condition_blocks (result : complete) =
  result.enabledness_condition_blocks
let head_domain_failures (result : complete) = result.head_domain_failures
let source_condition_certificates (result : complete) =
  result.source_condition_certificates
let source_condition_failures (result : complete) =
  result.source_condition_failures
let rule_conditions (result : complete) = result.rule_conditions
let has_else (result : complete) = result.has_else
let let_bound_ids (result : complete) = result.let_bound_ids
let env_after (result : complete) = result.env_after
let lhs_bound_vars (result : complete) = result.lhs_bound_vars
let bound_vars_after (result : complete) = result.bound_vars_after
let blocked_witness_source_ids (result : complete) =
  result.blocked_witness_source_ids
let runtime_search_requests (result : complete) =
  result.runtime_search_requests
let runtime_truth_search_requests (result : complete) =
  result.runtime_truth_search_requests
let runtime_truth_worklist_requests (result : complete) =
  result.runtime_truth_worklist_requests
let pattern_certificate (result : complete) = result.pattern_certificate
let diagnostics (result : complete) = result.diagnostics
