open Maude_ir

type no_hit_call =
  { op : string
  ; ok : string
  ; lhs : term
  ; rhs : term
  }

type rule_refuter =
  { index : int
  ; op : string
  ; ok : string
  ; sort : sort
  }

let generated helper_name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper helper_name) ~origin node

let no_hit_sort helper_name =
  sort ("RuntimeTruthNoHit" ^ Naming.sort_token helper_name ^ "Conf")
let no_hit_op = Naming.helper_companion ~role:"truth-no-hit"
let no_hit_ok_op = Naming.helper_companion ~role:"truth-no-hit-ok"
let all_rules_sort helper_name =
  sort ("RuntimeTruthAllRulesRefuted" ^ Naming.sort_token helper_name ^ "Conf")
let all_rules_op = Naming.helper_companion ~role:"truth-all-refuted"
let all_rules_ok_op = Naming.helper_companion ~role:"truth-all-refuted-ok"

let rule_refuter_sort helper_name index =
  sort
    ("RuntimeTruthRuleRefuted" ^ Naming.sort_token helper_name
     ^ string_of_int index ^ "Conf")

let rule_refuter_op helper_name index =
  Naming.helper_companion
    ~role:("truth-rule-refuted-" ^ string_of_int index) helper_name

let rule_refuter_ok_op helper_name index =
  Naming.helper_companion
    ~role:("truth-rule-refuted-ok-" ^ string_of_int index) helper_name

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ ->
    let rec range index = function
      | [] -> []
      | _ :: sorts -> index :: range (index + 1) sorts
    in
    [ Frozen (range 1 sorts) ]

let rule_refuter helper_name index =
  { index
  ; op = rule_refuter_op helper_name index
  ; ok = rule_refuter_ok_op helper_name index
  ; sort = rule_refuter_sort helper_name index
  }

let spectec_terminals = sort "SpectecTerminals"
let spectec_terminal = sort "SpectecTerminal"

let no_hit_call ~helper_name request : no_hit_call =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let op = no_hit_op helper_name in
  let ok = no_hit_ok_op helper_name in
  { op; ok; lhs = App (op, truth_request.input_terms); rhs = Const ok }

let all_rules_call ~helper_name input_terms =
  App (all_rules_op helper_name, input_terms)

let all_rules_ok helper_name = Const (all_rules_ok_op helper_name)
let rule_refuter_call (refuter : rule_refuter) input_terms =
  App (refuter.op, input_terms)

let rule_refuter_ok (refuter : rule_refuter) =
  Const refuter.ok

let all_rules_surface helper_name origin request =
  let truth = request.Runtime_truth_decision_helper.truth_request in
  let result_sort = all_rules_sort helper_name in
  [ generated helper_name origin (sort_decl result_sort)
  ; generated helper_name origin
      (op (all_rules_op helper_name) (List.map sort_ref truth.input_sorts)
         result_sort ~attrs:(frozen_all truth.input_sorts))
  ; generated helper_name origin
      (op (all_rules_ok_op helper_name) [] result_sort ~attrs:[ Ctor ])
  ]

let rule_refuter_surface helper_name origin request rules =
  let truth = request.Runtime_truth_decision_helper.truth_request in
  rules
  |> List.mapi (fun index _ ->
    let refuter = rule_refuter helper_name (index + 1) in
    [ generated helper_name origin (sort_decl refuter.sort)
    ; generated helper_name origin
        (op refuter.op (List.map sort_ref truth.input_sorts) refuter.sort
           ~attrs:(frozen_all truth.input_sorts))
    ; generated helper_name origin (op refuter.ok [] refuter.sort ~attrs:[ Ctor ])
    ])
  |> List.concat

let no_hit_surface helper_name origin request =
  let truth = request.Runtime_truth_decision_helper.truth_request in
  let result_sort = no_hit_sort helper_name in
  let call = no_hit_call ~helper_name request in
  [ generated helper_name origin (sort_decl result_sort)
  ; generated helper_name origin
      (op call.op (List.map sort_ref truth.input_sorts) result_sort
         ~attrs:(frozen_all truth.input_sorts))
  ; generated helper_name origin (op call.ok [] result_sort ~attrs:[ Ctor ])
  ]

let indexed_false_sort helper refuter prem =
  sort
    ("RuntimeTruthAllIndexedFalse" ^ helper ^ string_of_int refuter
     ^ "x" ^ string_of_int prem ^ "Conf")

let indexed_false_op helper refuter prem =
  "runtimeTruthAllIndexedFalse" ^ helper ^ string_of_int refuter
  ^ "x" ^ string_of_int prem

let indexed_false_ok_op helper refuter prem =
  "runtimeTruthAllIndexedFalseOk" ^ helper ^ string_of_int refuter
  ^ "x" ^ string_of_int prem

let indexed_head_no_match_sort helper refuter =
  sort
    ("RuntimeTruthIndexedHeadNoMatch" ^ helper ^ string_of_int refuter ^ "Conf")

let indexed_head_no_match_op helper refuter =
  "runtimeTruthIndexedHeadNoMatch" ^ helper ^ string_of_int refuter

let indexed_head_no_match_ok_op helper refuter =
  "runtimeTruthIndexedHeadNoMatchOk" ^ helper ^ string_of_int refuter

let indexed_false_call op source captures =
  App (op, source :: captures)

let indexed_head_no_match_call op target source =
  App (op, [ target; source ])
