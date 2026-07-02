type target =
  { target_rel_id : string option
  ; target_source : string option
  ; target_premise : Il.Ast.prem
  }

type guide =
  { guide_rel_id : string
  ; guide_source : string option
  ; guide_input_terms : Maude_ir.term list
  ; guide_input_sorts : Maude_ir.sort list
  ; guide_witness_index : int
  }

type request =
  { rel_id : string
  ; witness_source_id : string
  ; targets : target list
  ; guides : guide list
  ; input_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; witness_index : int
  ; witness_term : Maude_ir.term
  ; witness_sort : Maude_ir.sort
  ; dependent_source_ids : string list
  ; closure : string list
  ; rules : Analysis.Function_graph.runtime_search_rule list
  ; witness_space : Runtime_witness_space.t
  }

type invocation =
  { search_op : string
  ; hit_op : string
  ; lhs : Maude_ir.term
  ; rhs : Maude_ir.term
  }

let rec term_key = function
  | Maude_ir.Var name -> "V:" ^ name
  | Const name -> "C:" ^ name
  | Qid text -> "Q:" ^ text
  | App (op, args) ->
    "A:" ^ op ^ "(" ^ String.concat "," (List.map term_key args) ^ ")"

let key request =
  let rule_key (rule : Analysis.Function_graph.runtime_search_rule) =
    String.concat
      ":"
      [ rule.relation_id
      ; Option.value ~default:"" rule.rule_id
      ]
  in
  let target_key target =
    String.concat
      ":"
      [ Option.value ~default:"" target.target_rel_id
      ; Option.value ~default:"" target.target_source
      ]
  in
  let guide_key guide =
    String.concat
      ":"
      [ guide.guide_rel_id
      ; Option.value ~default:"" guide.guide_source
      ; String.concat "," (List.map term_key guide.guide_input_terms)
      ; String.concat "," (List.map Maude_ir.sort_name guide.guide_input_sorts)
      ; string_of_int guide.guide_witness_index
      ]
  in
  String.concat
    "\000"
    [ request.rel_id
    ; request.witness_source_id
    ; string_of_int request.witness_index
    ; String.concat "," (List.map target_key request.targets)
    ; String.concat "," (List.map guide_key request.guides)
    ; String.concat "," (List.map term_key request.input_terms)
    ; String.concat "," (List.map Maude_ir.sort_name request.input_sorts)
    ; term_key request.witness_term
    ; Maude_ir.sort_name request.witness_sort
    ; String.concat "," request.dependent_source_ids
    ; String.concat "," request.closure
    ; String.concat "," (List.map rule_key request.rules)
    ; Runtime_witness_space.key request.witness_space
    ]

let reason request =
  let target =
    let rel_ids =
      request.targets
      |> List.filter_map (fun target -> target.target_rel_id)
      |> List.sort_uniq String.compare
    in
    match rel_ids with
    | [] -> ""
    | [ rel_id ] -> " consumed by target predicate `" ^ rel_id ^ "`"
    | rel_ids ->
      " consumed by target predicates `"
      ^ String.concat "`, `" rel_ids
      ^ "`"
  in
  "runtime predicate local-existential search for witness `"
  ^ request.witness_source_id
  ^ "` in relation `"
  ^ request.rel_id
  ^ "`"
  ^ target
  ^ "; closure: "
  ^ String.concat " -> " request.closure

let search_op ~helper_name =
  "runtimeSearch" ^ helper_name

let hit_op ~helper_name =
  "runtimeSearchHit" ^ helper_name

let invocation ~helper_name request =
  let search_op = search_op ~helper_name in
  let hit_op = hit_op ~helper_name in
  { search_op
  ; hit_op
  ; lhs = Maude_ir.App (search_op, request.input_terms)
  ; rhs = Maude_ir.App (hit_op, [ request.witness_term ])
  }

let rewrite_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.rhs)
