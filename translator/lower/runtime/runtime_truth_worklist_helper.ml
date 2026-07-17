type mode = Prove | Decide

type request =
  { relation_id : string
  ; specialization : string
  ; input_terms : Maude_ir.term list
  ; input_sorts : Maude_ir.sort list
  ; phase : Runtime_truth_scc.phase
  ; mode : mode
  ; plan : Runtime_truth_scc.t
  }

type invocation =
  { worklist_op : string
  ; proved_op : string
  ; refuted_op : string
  ; lhs : Maude_ir.term
  ; proved_rhs : Maude_ir.term
  ; refuted_rhs : Maude_ir.term
  }

let field text = string_of_int (String.length text) ^ ":" ^ text

let list key values =
  "L" ^ string_of_int (List.length values) ^ ":"
  ^ String.concat "" (List.map (fun value -> field (key value)) values)

let rec term_key = function
  | Maude_ir.Var name -> "V" ^ field name
  | Const name -> "C" ^ field name
  | Qid text -> "Q" ^ field text
  | App (op, args) -> "A" ^ field op ^ list term_key args

let rec premise_key = function
  | Runtime_truth_scc.Finite_rule_call { relation_id; premise } ->
    "call" ^ field relation_id ^ field (Il.Print.string_of_prem premise)
  | Finite_domain_call premise ->
    "domain" ^ field (Il.Print.string_of_prem premise)
  | Finite_successor_call { relation_id; introduced; premise } ->
    "successor" ^ field relation_id ^ list Fun.id introduced
    ^ field (Il.Print.string_of_prem premise)
  | Deterministic_total premise ->
    "total" ^ field (Il.Print.string_of_prem premise)
  | Externally_validated premise ->
    "external" ^ field (Il.Print.string_of_prem premise)
  | Source_boolean premise ->
    "source-boolean" ^ field (Il.Print.string_of_prem premise)
  | Deterministic_binding_iter premise ->
    "binding-iter" ^ field (Il.Print.string_of_prem premise)
  | Finite_iter { phase; premise; body } ->
    "iter" ^ field (Runtime_truth_scc.phase_key phase)
    ^ field (Il.Print.string_of_prem premise) ^ list premise_key body

let rule_key (rule : Runtime_truth_scc.rule) =
  let source = rule.source in
  "rule"
  ^ field (Source_rule_identity.rule_key source.identity)
  ^ list premise_key rule.premises
  ^ list string_of_int rule.schedule

let scc_key (scc : Runtime_truth_scc.scc) =
  "scc" ^ field (string_of_int scc.index)
  ^ list Fun.id scc.relations ^ list rule_key scc.rules

let program_key request =
  "runtime-truth-worklist"
  ^ field request.relation_id
  ^ field request.specialization
  ^ field (Runtime_truth_scc.phase_key request.phase)
  ^ field (match request.mode with Prove -> "prove" | Decide -> "decide")
  ^ list Maude_ir.sort_name request.input_sorts
  ^ list Fun.id request.plan.closure
  ^ list scc_key request.plan.sccs
  ^ list Runtime_truth_successor_domain.key request.plan.successor_domains

let key request =
  program_key request
  ^ list term_key request.input_terms

let reason request =
  (match request.mode with
   | Prove -> "finite ground positive runtime truth SCC worklist for relation `"
   | Decide -> "finite ground total runtime truth SCC worklist for relation `")
  ^ request.relation_id
  ^ "` (phase " ^ Runtime_truth_scc.phase_key request.phase ^ ")"

let worklist_op name = name
let proved_op = Naming.helper_companion ~role:"truth-proved"
let refuted_op = Naming.helper_companion ~role:"truth-refuted"

let invocation ~helper_name request =
  let worklist_op = worklist_op helper_name in
  let proved_op = proved_op helper_name in
  let refuted_op = refuted_op helper_name in
  { worklist_op
  ; proved_op
  ; refuted_op
  ; lhs = Maude_ir.App (worklist_op, request.input_terms)
  ; proved_rhs = Maude_ir.Const proved_op
  ; refuted_rhs = Maude_ir.Const refuted_op
  }

let true_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.proved_rhs)

let false_condition ~helper_name request =
  let call = invocation ~helper_name request in
  Maude_ir.RewriteCond (call.lhs, call.refuted_rhs)

let surface ~helper_name ~origin request =
  let open Maude_ir in
  let generated node =
    generated ~provenance:(Helper helper_name) ~origin node
  in
  let result =
    sort ("RuntimeTruthWorklist" ^ Naming.sort_token helper_name ^ "Conf")
  in
  let frozen =
    match request.input_sorts with
    | [] -> []
    | sorts -> [ Frozen (List.mapi (fun index _ -> index + 1) sorts) ]
  in
  let call = invocation ~helper_name request in
  [ generated (sort_decl result)
  ; generated
      (op call.worklist_op (List.map sort_ref request.input_sorts) result
         ~attrs:frozen)
  ; generated (op call.proved_op [] result ~attrs:[ Ctor ])
  ]
  @ match request.mode with
    | Prove -> []
    | Decide -> [ generated (op call.refuted_op [] result ~attrs:[ Ctor ]) ]
