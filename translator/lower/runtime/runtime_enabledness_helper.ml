type truth_decision =
  { helper_name : string
  ; request : Runtime_truth_decision_helper.request
  }

type worklist_decision = Runtime_truth_worklist_enabledness.decision

type request =
  { relation_id : string
  ; rule_id : string option
  ; call_terms : Maude_ir.term list
  ; predecessor_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; lhs_conditions : Maude_ir.eq_condition list
  ; premise_eq_conditions : Maude_ir.eq_condition list
  ; premise_rule_conditions : Maude_ir.rule_condition list
  ; runtime_search_requests : Runtime_search_helper.request list
  ; runtime_truth_search_requests : Runtime_truth_search_helper.request list
  ; runtime_truth_decisions : truth_decision list
  ; runtime_truth_worklist_decisions : worklist_decision list
  ; source_echo : string option
  }

type invocation =
  { enabled_op : string
  ; true_op : string
  ; false_op : string
  ; lhs : Maude_ir.term
  ; true_rhs : Maude_ir.term
  ; false_rhs : Maude_ir.term
  }

let rec term_key = function
  | Maude_ir.Var name -> "V:" ^ name
  | Const name -> "C:" ^ name
  | Qid text -> "Q:" ^ text
  | App (op, args) ->
    "A:" ^ op ^ "(" ^ String.concat "," (List.map term_key args) ^ ")"

let eq_condition_key = function
  | Maude_ir.BoolCond term -> "B:" ^ term_key term
  | EqCond (left, right) -> "E:" ^ term_key left ^ "=" ^ term_key right
  | MatchCond (left, right) -> "M:" ^ term_key left ^ ":=" ^ term_key right
  | MembershipCond (term, sort) ->
    "Mb:" ^ term_key term ^ ":" ^ Maude_ir.sort_name sort

let rule_condition_key = function
  | Maude_ir.EqCondition condition -> "EQ:" ^ eq_condition_key condition
  | RewriteCond (left, right) -> "RW:" ^ term_key left ^ "=>" ^ term_key right

let truth_decision_key decision =
  Runtime_truth_decision_helper.key decision.request

let key request =
  String.concat
    "\000"
    [ request.relation_id
    ; Option.value ~default:"" request.rule_id
    ; String.concat "," (List.map term_key request.call_terms)
    ; String.concat "," (List.map term_key request.predecessor_terms)
    ; String.concat "," (List.map Maude_ir.sort_name request.input_sorts)
    ; String.concat "," (List.map eq_condition_key request.lhs_conditions)
    ; String.concat "," (List.map eq_condition_key request.premise_eq_conditions)
    ; String.concat "," (List.map rule_condition_key request.premise_rule_conditions)
    ; String.concat "," (List.map Runtime_search_helper.key request.runtime_search_requests)
    ; String.concat "," (List.map Runtime_truth_search_helper.key request.runtime_truth_search_requests)
    ; String.concat "," (List.map truth_decision_key request.runtime_truth_decisions)
    ; String.concat ","
        (List.map Runtime_truth_worklist_enabledness.key
           request.runtime_truth_worklist_decisions)
    ]

let reason request =
  let rule =
    match request.rule_id with
    | None -> ""
    | Some rule_id -> "/" ^ rule_id
  in
  "runtime enabledness decision for predecessor `"
  ^ request.relation_id
  ^ rule
  ^ "`"

let enabled_op ~helper_name =
  helper_name

let true_op ~helper_name =
  Naming.helper_companion ~role:"enabled-true" helper_name

let false_op ~helper_name =
  Naming.helper_companion ~role:"enabled-false" helper_name

let invocation ~helper_name request =
  let enabled_op = enabled_op ~helper_name in
  let true_op = true_op ~helper_name in
  let false_op = false_op ~helper_name in
  { enabled_op
  ; true_op
  ; false_op
  ; lhs = Maude_ir.App (enabled_op, request.call_terms)
  ; true_rhs = Maude_ir.Const true_op
  ; false_rhs = Maude_ir.Const false_op
  }

let false_rewrite_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.false_rhs)

let surface ~helper_name ~origin request =
  let open Maude_ir in
  let generated node =
    generated ~provenance:(Helper helper_name) ~origin node
  in
  let result =
    sort ("RuntimeEnabledness" ^ Naming.sort_token helper_name ^ "Conf")
  in
  let frozen =
    match request.input_sorts with
    | [] -> []
    | sorts -> [ Frozen (List.mapi (fun index _ -> index + 1) sorts) ]
  in
  let call = invocation ~helper_name request in
  [ generated (sort_decl result)
  ; generated
      (op call.enabled_op (List.map sort_ref request.input_sorts) result
         ~attrs:frozen)
  ; generated (op call.true_op [] result ~attrs:[ Ctor ])
  ; generated (op call.false_op [] result ~attrs:[ Ctor ])
  ]
