type result =
  { term : Maude_ir.term option
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type pattern_result =
  { pattern_term : Maude_ir.term option
  ; pattern_guards : Maude_ir.eq_condition list
  ; introduced_bindings : (string * Expr_env.binding) list
  ; pattern_diagnostics : Diagnostics.t list
  }

let empty_result = { term = None; guards = []; diagnostics = [] }

let with_term term =
  { empty_result with term = Some term }

let with_diagnostics diagnostics =
  { empty_result with diagnostics }

let append_result_metadata results =
  let guards = List.concat_map (fun result -> result.guards) results in
  let diagnostics = List.concat_map (fun result -> result.diagnostics) results in
  guards, diagnostics

let terms results =
  let terms = List.filter_map (fun result -> result.term) results in
  if List.length terms = List.length results then Some terms else None
