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
  Source_rule_identity.rule_key rule.identity

let rec term_key = function
  | Maude_ir.Var name -> "var:" ^ name
  | Maude_ir.Const name -> "const:" ^ name
  | Maude_ir.Qid text -> "qid:" ^ text
  | Maude_ir.App (op, args) ->
    "app:" ^ op ^ "(" ^ String.concat "," (List.map term_key args) ^ ")"

let rec closed_term = function
  | Maude_ir.Var _ -> false
  | Maude_ir.Const _ | Maude_ir.Qid _ -> true
  | Maude_ir.App (_, args) -> List.for_all closed_term args

let specialized_input_key terms =
  terms
  |> List.mapi (fun index term -> index, term)
  |> List.filter_map (fun (index, term) ->
    if closed_term term then Some (string_of_int index ^ ":" ^ term_key term)
    else None)
  |> String.concat ","

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
    ; "closed-inputs:" ^ specialized_input_key request.input_terms
    ; String.concat "," request.closure
    ; String.concat "," (List.map rule_key request.rules)
    ]

let reason request =
  "runtime predicate truth search for relation `"
  ^ request.rel_id
  ^ "`; closure: "
  ^ String.concat " -> " request.closure

let search_op ~helper_name =
  helper_name

let ok_op ~helper_name =
  Naming.helper_companion ~role:"truth-search-ok" helper_name

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

let surface ~helper_name ~origin request =
  let result_sort =
    Maude_ir.sort ("RuntimeTruth" ^ Naming.sort_token helper_name ^ "Conf")
  in
  let frozen =
    match request.input_sorts with
    | [] -> []
    | sorts ->
      [ Maude_ir.Frozen
          (List.mapi (fun index _ -> index + 1) sorts) ]
  in
  let generated node =
    Maude_ir.generated
      ~provenance:(Maude_ir.Helper helper_name) ~origin node
  in
  [ generated (Maude_ir.sort_decl result_sort)
  ; generated
      (Maude_ir.op
         (search_op ~helper_name)
         (List.map Maude_ir.sort_ref request.input_sorts)
         result_sort ~attrs:frozen)
  ; generated
      (Maude_ir.op (ok_op ~helper_name) [] result_sort
         ~attrs:[ Maude_ir.Ctor ])
  ]
