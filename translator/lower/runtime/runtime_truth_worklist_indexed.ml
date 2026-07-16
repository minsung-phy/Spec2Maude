open Maude_ir

type capture =
  { call_term : term
  ; formal_var : string
  ; sort : sort
  }

type phase =
  | Rule_premise
  | Seed_premise
  | Transitive

type identity =
  { phase : phase
  ; rule_index : int
  ; premise_index : int option
  }

type mode = Prove | Decide

type request =
  { helper_name : string
  ; origin : Origin.t
  ; identity : identity
  ; mode : mode
  ; source_term : term
  ; captures : capture list
  ; head_var : string
  ; tail_var : string
  ; body_true : rule_condition list
  ; body_false : rule_condition list list
  ; result_sort : sort
  ; proved : term
  ; refuted : term
  }

type result =
  { statements : generated list
  ; true_condition : rule_condition
  ; false_condition : rule_condition option
  }

let generated request node =
  Maude_ir.generated ~provenance:(Helper request.helper_name)
    ~origin:request.origin node

let phase_name = function
  | Rule_premise -> "RulePremise"
  | Seed_premise -> "SeedPremise"
  | Transitive -> "Transitive"

let identity_name identity =
  phase_name identity.phase
  ^ "Rule" ^ string_of_int identity.rule_index
  ^ match identity.premise_index with
    | None -> ""
    | Some index -> "Premise" ^ string_of_int index

let true_op request =
  "runtimeTruthIndexedExists" ^ request.helper_name
  ^ identity_name request.identity

let false_op request =
  "runtimeTruthIndexedAllFalse" ^ request.helper_name
  ^ identity_name request.identity

let frozen_all count =
  if count = 0 then [] else [ Frozen (List.init count (fun index -> index + 1)) ]

let materialize request =
  let sequence = sort "SpectecTerminals" in
  let capture_sorts = List.map (fun capture -> capture.sort) request.captures in
  let capture_vars = List.map (fun capture -> Var capture.formal_var) request.captures in
  let args = List.map sort_ref (sequence :: capture_sorts) in
  let true_op = true_op request and false_op = false_op request in
  let head = Var request.head_var and tail = Var request.tail_var in
  let cons = App ("_ _", [ head; tail ]) in
  let true_call source = App (true_op, source :: capture_vars) in
  let false_call source = App (false_op, source :: capture_vars) in
  let declarations =
    [ generated request
        (op true_op args request.result_sort ~attrs:(frozen_all (List.length args)))
    ]
    @ (match request.mode with
       | Prove -> []
       | Decide ->
         [ generated request
             (op false_op args request.result_sort
                ~attrs:(frozen_all (List.length args))) ])
  in
  let false_rules = match request.mode with
    | Prove -> []
    | Decide ->
      [ generated request
          (rl ~label:(false_op ^ "-empty")
             (false_call (Const "eps")) request.refuted) ]
      @ (request.body_false
         |> List.mapi (fun index conditions ->
           generated request
             (crl ~label:(false_op ^ "-cons-" ^ string_of_int (index + 1))
                (false_call cons) request.refuted
                (conditions @ [ RewriteCond (false_call tail, request.refuted) ]))))
  in
  let statements = declarations
    @ [ generated request
          (crl ~label:(true_op ^ "-head")
             (true_call cons) request.proved request.body_true)
      ; generated request
          (crl ~label:(true_op ^ "-tail")
             (true_call cons) request.proved
             [ RewriteCond (true_call tail, request.proved) ])
      ]
    @ false_rules
  in
  { statements
  ; true_condition =
      RewriteCond
        (App (true_op, request.source_term :: List.map (fun capture -> capture.call_term) request.captures),
         request.proved)
  ; false_condition =
      (match request.mode with
      | Prove -> None
      | Decide ->
        Some
          (RewriteCond
             (App (false_op,
                    request.source_term
                    :: List.map (fun capture -> capture.call_term) request.captures),
              request.refuted)))
  }
