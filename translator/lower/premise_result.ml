type result =
  { eq_conditions : Maude_ir.eq_condition list
  ; rule_conditions : Maude_ir.rule_condition list
  ; has_else : bool
  ; let_bound_ids : string list list
  ; env_after : Expr_translate.env
  ; bound_vars_after : string list
  ; blocked_witness_source_ids : string list
  ; runtime_search_requests : Runtime_search_helper.request list
  ; runtime_truth_search_requests : Runtime_truth_search_helper.request list
  ; diagnostics : Diagnostics.t list
  }

let normalize_vars vars =
  vars |> List.sort_uniq String.compare

let empty_with_env ?(bound_vars = []) env =
  { eq_conditions = []
  ; rule_conditions = []
  ; has_else = false
  ; let_bound_ids = []
  ; env_after = env
  ; bound_vars_after = normalize_vars bound_vars
  ; blocked_witness_source_ids = []
  ; runtime_search_requests = []
  ; runtime_truth_search_requests = []
  ; diagnostics = []
  }

let empty = empty_with_env Expr_translate.empty_env

let append left right =
  { eq_conditions = left.eq_conditions @ right.eq_conditions
  ; rule_conditions = left.rule_conditions @ right.rule_conditions
  ; has_else = left.has_else || right.has_else
  ; let_bound_ids = left.let_bound_ids @ right.let_bound_ids
  ; env_after = right.env_after
  ; bound_vars_after = right.bound_vars_after
  ; blocked_witness_source_ids =
      normalize_vars
        (left.blocked_witness_source_ids @ right.blocked_witness_source_ids)
  ; runtime_search_requests =
      left.runtime_search_requests @ right.runtime_search_requests
  ; runtime_truth_search_requests =
      left.runtime_truth_search_requests @ right.runtime_truth_search_requests
  ; diagnostics = left.diagnostics @ right.diagnostics
  }
