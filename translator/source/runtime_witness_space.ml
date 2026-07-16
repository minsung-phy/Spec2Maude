open Il.Ast
open Util.Source

type target =
  { target_rel_id : string option
  ; target_source : string option
  ; target_premise : prem
  }

type blocker =
  { relation_id : string
  ; rule_id : string option
  ; origin : Origin.t option
  ; constructor : string
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

type t =
  { rel_id : string
  ; witness_source_id : string
  ; target_rel_ids : string list
  ; closure : string list
  ; rules : Analysis.Function_graph.runtime_search_rule list
  ; proof : Runtime_witness_proof.t
  ; key : string
  }

let key t =
  t.key

let closure t =
  t.closure

let rules t =
  t.rules

let proof t =
  t.proof

let target_rel_ids targets =
  targets
  |> List.filter_map (fun target -> target.target_rel_id)
  |> List.sort_uniq String.compare

let blocker relation_id ?rule_id ?origin ?source_echo constructor reason suggestion =
  { relation_id
  ; rule_id
  ; origin
  ; constructor
  ; reason
  ; suggestion
  ; source_echo
  }

let blocker_of_rule rule constructor reason suggestion =
  blocker
    rule.Analysis.Function_graph.relation_id
    ?rule_id:rule.rule_id
    ~origin:rule.origin
    ?source_echo:rule.source_echo
    constructor
    reason
    suggestion

let rec premise_edges acc prem =
  match prem.it with
  | RulePr (id, [], _, _) -> id.it :: acc
  | RulePr (_, _ :: _, _, _) -> acc
  | IfPr _ | LetPr _ | ElsePr -> acc
  | IterPr (body, _) | NegPr body -> premise_edges acc body

let rule_edges (rule : Analysis.Function_graph.runtime_search_rule) =
  rule.prems
  |> List.fold_left premise_edges []
  |> List.sort_uniq String.compare

let relation_edges closure rule =
  rule_edges rule
  |> List.filter (fun id -> List.mem id closure)

let graph_edges closure rules =
  let add_rule edges rule =
    let relation_id = rule.Analysis.Function_graph.relation_id in
    let existing =
      match List.assoc_opt relation_id edges with
      | Some ids -> ids
      | None -> []
    in
    let next =
      relation_edges closure rule @ existing
      |> List.sort_uniq String.compare
    in
    (relation_id, next)
    :: List.remove_assoc relation_id edges
  in
  rules |> List.fold_left add_rule []

let find_cycle closure rules =
  let edges = graph_edges closure rules in
  let successors id =
    match List.assoc_opt id edges with
    | Some ids -> ids
    | None -> []
  in
  let rec visit path id =
    if List.mem id path then
      Some (List.rev (id :: path))
    else
      successors id
      |> List.find_map (visit (id :: path))
  in
  closure |> List.find_map (visit [])

let source_rule_of_runtime_rule
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  { Runtime_witness_proof.identity = rule.identity
  ; relation_id = rule.relation_id
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; source_echo = rule.source_echo
  ; head = rule.head
  ; prems = rule.prems
  }

let transitive_witness_rule rule =
  let source_rule = source_rule_of_runtime_rule rule in
  Runtime_witness_proof.transitive_domain source_rule

let target_chain_rule rule =
  let source_rule = source_rule_of_runtime_rule rule in
  Runtime_witness_proof.target_chain source_rule

let transitive_witness_blocker
    cycle_text
    (candidate : Runtime_witness_proof.transitive_domain)
  =
  let rule = candidate.Runtime_witness_proof.rule in
  blocker
    rule.relation_id
    ?rule_id:rule.rule_id
    ~origin:rule.origin
    ?source_echo:rule.source_echo
    "RuntimeWitnessSpace/finite-transitive-closure-needed"
    ("runtime witness search closure contains recursive predicate dependency cycle `"
     ^ cycle_text
     ^ "`; rule has a domain predicate and multiple recursive predicate premises")
    "Materialize this only after proving a finite witness domain and fuel/visited measure for the transitive source relation; do not emit partial base rules or a deterministic witness function"

let finite_transitive_proof cycle rules =
  let cycle_ids = cycle |> List.sort_uniq String.compare in
  let cycle_rules =
    rules
    |> List.filter (fun rule ->
      List.mem rule.Analysis.Function_graph.relation_id cycle_ids)
  in
  match cycle_rules |> List.filter_map transitive_witness_rule with
  | [ candidate ] ->
    Some (Runtime_witness_proof.closed_world_domain ~cycle_rel_ids:cycle_ids candidate)
  | _ -> None

let target_chain_proof cycle rules =
  let cycle_ids = cycle |> List.sort_uniq String.compare in
  let cycle_rules =
    rules
    |> List.filter (fun rule ->
      List.mem rule.Analysis.Function_graph.relation_id cycle_ids)
  in
  match cycle_rules |> List.filter_map target_chain_rule with
  | [ candidate ]
    when List.for_all
           (fun rule ->
             let source_rule = candidate.Runtime_witness_proof.rule in
             String.equal
               rule.Analysis.Function_graph.relation_id
               source_rule.Runtime_witness_proof.relation_id)
           cycle_rules ->
    Some candidate
  | _ -> None

let target_chain_for_relation rel_id rules =
  let local_rules =
    rules
    |> List.filter (fun rule ->
      String.equal rule.Analysis.Function_graph.relation_id rel_id)
  in
  match local_rules |> List.filter_map target_chain_rule with
  | [ candidate ] -> Some candidate
  | [] | _ :: _ :: _ -> None

let finite_transitive_for_relation rel_id rules =
  let local_rules =
    rules
    |> List.filter (fun rule ->
      String.equal rule.Analysis.Function_graph.relation_id rel_id)
  in
  match local_rules |> List.filter_map transitive_witness_rule with
  | [ candidate ] ->
    Some
      (Runtime_witness_proof.closed_world_domain
         ~cycle_rel_ids:[ rel_id ]
         candidate)
  | [] | _ :: _ :: _ -> None

let cycle_blockers rules cycle =
  let cycle_text = String.concat " -> " cycle in
  let cycle_ids = cycle |> List.sort_uniq String.compare in
  let cycle_rules =
    rules
    |> List.filter (fun rule ->
      List.mem rule.Analysis.Function_graph.relation_id cycle_ids)
  in
  match cycle_rules |> List.filter_map transitive_witness_rule with
  | _ :: _ as candidates ->
    candidates |> List.map (transitive_witness_blocker cycle_text)
  | [] ->
    (match cycle_rules |> List.filter_map target_chain_rule with
    | _ :: _ as candidates ->
      candidates
      |> List.map (fun candidate ->
        let rule = candidate.Runtime_witness_proof.rule in
        blocker
          rule.relation_id
          ?rule_id:rule.rule_id
          ~origin:rule.origin
          ?source_echo:rule.source_echo
          "RuntimeWitnessSpace/target-guided-self-needed"
          ("runtime witness search closure contains target-guided recursive predicate dependency cycle `"
           ^ cycle_text
           ^ "`")
          "Materialize this only as a source-complete target-guided rewrite search; do not emit base cases without the source sub/target rule")
    | [] ->
      cycle_rules
      |> List.map (fun rule ->
        blocker_of_rule
          rule
          "RuntimeWitnessSpace/recursive-cycle"
          ("runtime witness search closure contains recursive predicate dependency cycle `"
           ^ cycle_text
           ^ "`")
          "Provide a bounded/source-complete recursive witness strategy before materializing this search helper"))

let key_of rel_id witness_source_id target_rel_ids closure rules proof =
  let rule_key (rule : Analysis.Function_graph.runtime_search_rule) =
    String.concat
      ":"
      [ rule.relation_id
      ; Option.value ~default:"" rule.rule_id
      ; Option.value ~default:"" rule.source_echo
      ]
  in
  Digest.to_hex
    (Digest.string
       (String.concat
          "\000"
          [ rel_id
          ; witness_source_id
          ; String.concat "," target_rel_ids
          ; String.concat "," closure
          ; String.concat "," (List.map rule_key rules)
          ; Runtime_witness_proof.key proof
          ]))

let proof_for_closure ~closure ~rules =
  match find_cycle closure rules with
  | Some cycle ->
    (match finite_transitive_proof cycle rules with
    | Some domain -> Ok (Runtime_witness_proof.finite_transitive domain)
    | None ->
      (match target_chain_proof cycle rules with
      | Some target -> Ok (Runtime_witness_proof.target_guided_self target)
      | None -> Error (cycle_blockers rules cycle)))
  | None -> Ok Runtime_witness_proof.acyclic

let proof_for_truth_relation ~rel_id ~closure ~rules =
  match target_chain_for_relation rel_id rules with
  | Some target -> Ok (Runtime_witness_proof.target_guided_self target)
  | None ->
    (match finite_transitive_for_relation rel_id rules with
    | Some domain -> Ok (Runtime_witness_proof.finite_transitive domain)
    | None ->
      let _ = closure in
      Ok Runtime_witness_proof.acyclic)

let prove ~rel_id ~witness_source_id ~targets ~closure ~rules =
  match targets, rules with
  | [], _ ->
    Error
      [ blocker
          rel_id
          "RuntimeWitnessSpace/no-target"
          "runtime witness search has no later target predicate consuming the witness"
          "Keep this helper unmaterialized until the source block has a target predicate that uses the witness"
      ]
  | _, [] ->
    Error
      [ blocker
          rel_id
          "RuntimeWitnessSpace/no-rules"
          "runtime witness search has no source RuleD clauses to materialize"
          "Keep this helper unmaterialized until the referenced relation body is available"
      ]
  | _ ->
    let proof_result =
      match target_chain_for_relation rel_id rules with
      | Some target -> Ok (Runtime_witness_proof.target_guided_self target)
      | None -> proof_for_closure ~closure ~rules
    in
    (match proof_result with
    | Ok proof ->
      let target_rel_ids = target_rel_ids targets in
      Ok
        { rel_id
        ; witness_source_id
        ; target_rel_ids
        ; closure
        ; rules
        ; proof
        ; key = key_of rel_id witness_source_id target_rel_ids closure rules proof
        }
    | Error blockers -> Error blockers)
