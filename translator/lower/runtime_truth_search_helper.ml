type recursion =
  | Acyclic
  | Finite_transitive of Runtime_witness_proof.closed_world_domain
  | Target_guided_self of Runtime_witness_proof.target_chain
  | Recursive of string list

type request =
  { rel_id : string
  ; input_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; recursion : recursion
  ; closure : string list
  ; rules : Analysis.Function_graph.runtime_search_rule list
  }

type invocation =
  { search_op : string
  ; ok_op : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

let rule_key (rule : Analysis.Function_graph.runtime_search_rule) =
  String.concat
    ":"
    [ rule.relation_id
    ; Option.value ~default:"" rule.rule_id
    ]

let key request =
  let recursion_key =
    match request.recursion with
    | Acyclic -> "acyclic"
    | Finite_transitive domain ->
      "finite-transitive:" ^ Runtime_witness_proof.key
        (Runtime_witness_proof.finite_transitive domain)
    | Target_guided_self target ->
      "target-guided-self:" ^ target.Runtime_witness_proof.target_rel_id
      ^ ":" ^ target.witness_source_id
    | Recursive cycle -> "recursive:" ^ String.concat "->" cycle
  in
  String.concat
    "\000"
    [ request.rel_id
    ; String.concat "," (List.map Maude_ir.sort_name request.input_sorts)
    ; recursion_key
    ; String.concat "," request.closure
    ; String.concat "," (List.map rule_key request.rules)
    ]

let reason request =
  "runtime predicate truth search for relation `"
  ^ request.rel_id
  ^ "`; closure: "
  ^ String.concat " -> " request.closure

let search_op ~helper_name =
  "runtimeTruthSearch" ^ helper_name

let ok_op ~helper_name =
  "runtimeTruthOk" ^ helper_name

let invocation ~helper_name request =
  let search_op = search_op ~helper_name in
  let ok_op = ok_op ~helper_name in
  { search_op
  ; ok_op
  ; lhs = Maude_ir.App (search_op, request.input_terms)
  ; rhs = Maude_ir.Const ok_op
  }

let rewrite_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.rhs)
