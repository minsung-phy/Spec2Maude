open Util.Source

let contains_source_premise source_premise prems =
  prems
  |> List.exists (fun prem ->
    Il.Print.string_of_prem prem
    = Il.Print.string_of_prem source_premise)

let is_target_guided_source_rule target rule =
  contains_source_premise
    target.Runtime_witness_proof.recursive_premise
    rule.Analysis.Function_graph.prems
  && contains_source_premise
       target.Runtime_witness_proof.target_premise
       rule.prems

let split_source_target_input prefix_arity components =
  let rec take n acc rest =
    if n = 0 then Some (List.rev acc, rest)
    else
      match rest with
      | [] -> None
      | exp :: rest -> take (n - 1) (exp :: acc) rest
  in
  match take prefix_arity [] components with
  | Some (_prefix, [ left; right ]) -> Some (left, right)
  | Some _ | None -> None

let seed_head_key (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.CaseE (mixop, _) ->
    Some ("case:" ^ Analysis.Relation_graph.mixop_shape_text mixop)
  | Il.Ast.VarE _ -> None
  | Il.Ast.BoolE _ | Il.Ast.NumE _ | Il.Ast.TextE _
  | Il.Ast.UnE _ | Il.Ast.BinE _ | Il.Ast.CmpE _
  | Il.Ast.TupE _ | Il.Ast.ProjE _ | Il.Ast.UncaseE _
  | Il.Ast.OptE _ | Il.Ast.TheE _ | Il.Ast.StrE _
  | Il.Ast.DotE _ | Il.Ast.CompE _ | Il.Ast.ListE _
  | Il.Ast.LiftE _ | Il.Ast.MemE _ | Il.Ast.LenE _
  | Il.Ast.CatE _ | Il.Ast.IdxE _ | Il.Ast.SliceE _
  | Il.Ast.UpdE _ | Il.Ast.ExtE _ | Il.Ast.IfE _
  | Il.Ast.CallE _ | Il.Ast.IterE _ | Il.Ast.CvtE _
  | Il.Ast.SubE _ -> None

let target_guided_seed_is_functional_for_truth_request truth_request target =
  let rel_id = truth_request.Runtime_truth_search_helper.rel_id in
  let input_count = List.length truth_request.input_terms in
  let seed_rules =
    truth_request.rules
    |> List.filter (fun rule ->
      String.equal rule.Analysis.Function_graph.relation_id rel_id
      && not (is_target_guided_source_rule target rule))
  in
  let keys =
    seed_rules
    |> List.map (fun (rule : Analysis.Function_graph.runtime_search_rule) ->
      match
        Analysis.Relation_graph.exp_components_for_count input_count rule.head
      with
      | Some components ->
        (match
           split_source_target_input
             target.Runtime_witness_proof.prefix_arity
             components
         with
        | Some (left, _witness) -> seed_head_key left
        | None -> None)
      | None -> None)
  in
  keys <> []
  && List.for_all Option.is_some keys
  &&
  let keys = List.filter_map (fun key -> key) keys in
  List.length keys = List.length (List.sort_uniq String.compare keys)

let target_guided_seed_is_functional request target =
  target_guided_seed_is_functional_for_truth_request
    request.Runtime_truth_decision_helper.truth_request
    target

let source_rule_relation_id rule =
  rule.Analysis.Function_graph.relation_id

let same_source_rule
    (source_rule : Runtime_witness_proof.source_rule)
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  match source_rule.rule_id, rule.rule_id with
  | Some source_id, Some rule_id when String.equal source_id rule_id -> true
  | _ ->
    String.equal
      (Origin.source_location source_rule.origin)
      (Origin.source_location rule.origin)

let local_relation_rules rel_id rules =
  rules
  |> List.filter (fun rule ->
    String.equal (source_rule_relation_id rule) rel_id)

let rule_text rel_id (rule : Analysis.Function_graph.runtime_search_rule) =
  match rule.rule_id with
  | Some id -> "RuleD `" ^ id ^ "` in relation `" ^ rel_id ^ "`"
  | None -> "source RuleD in relation `" ^ rel_id ^ "`"

type t =
  | Supported
  | Blocked of string list

let blocked text =
  Blocked [ text ]

let is_supported = function
  | Supported -> true
  | Blocked _ -> false

let blockers = function
  | Supported -> []
  | Blocked blockers -> blockers

let all supports =
  if List.for_all is_supported supports then
    Supported
  else
    Blocked (List.concat_map blockers supports)

let witness_space_blockers blockers =
  blockers
  |> List.map (fun (blocker : Runtime_witness_space.blocker) ->
    blocker.reason)

let rec for_rel ctx seen closure rules rel_id =
  if List.mem rel_id seen then
    match
      Runtime_witness_space.proof_for_truth_relation ~rel_id ~closure ~rules
    with
    | Ok proof ->
      (match Runtime_witness_proof.recursion proof with
      | Runtime_witness_proof.Acyclic
      | Runtime_witness_proof.Finite_transitive _ -> Supported
      | Runtime_witness_proof.Target_guided_self _ ->
        blocked
          ("recursive runtime truth false-support dependency revisits relation `"
           ^ rel_id
           ^ "`"))
    | Error blockers -> Blocked (witness_space_blockers blockers)
  else
    match
      Runtime_witness_space.proof_for_truth_relation ~rel_id ~closure ~rules
    with
    | Error blockers -> Blocked (witness_space_blockers blockers)
    | Ok proof ->
      (match Runtime_witness_proof.recursion proof with
      | Runtime_witness_proof.Acyclic ->
        acyclic ctx (rel_id :: seen) closure rules rel_id
      | Runtime_witness_proof.Target_guided_self target ->
        target_guided ctx (rel_id :: seen) closure rules target
      | Runtime_witness_proof.Finite_transitive domain ->
        finite_transitive ctx (rel_id :: seen) closure rules rel_id domain)

and acyclic ctx seen closure rules rel_id =
  match local_relation_rules rel_id rules with
  | [] ->
    blocked
      ("relation `" ^ rel_id ^ "` has no local source rules to refute")
  | local_rules ->
    local_rules
    |> List.map (rule ctx ~allow_self:false seen closure rules rel_id)
    |> all

and target_guided ctx seen closure rules target =
  for_rel
    ctx
    seen
    closure
    rules
    target.Runtime_witness_proof.target_rel_id

and premise ctx ~allow_self seen closure rules rel_id prem =
  match prem.it with
  | Il.Ast.IfPr _ -> Supported
  | Il.Ast.RulePr (dep_rel_id, [], _, exp) ->
    let dep_rel_id = dep_rel_id.it in
    if String.equal dep_rel_id rel_id then
      if allow_self then
        Supported
      else
        blocked
          ("recursive premise revisits relation `"
           ^ rel_id
           ^ "` without a finite no-hit proof")
    else
      (match Runtime_truth_deterministic_false.check ctx ~rel_id:dep_rel_id ~exp with
      | Runtime_truth_deterministic_false.Supported -> Supported
      | Runtime_truth_deterministic_false.Blocked blockers ->
        Blocked
          (List.map
             (fun blocker ->
               "deterministic RulePr premise for relation `"
               ^ dep_rel_id
               ^ "` has no source-complete false support: "
               ^ blocker)
             blockers)
      | Runtime_truth_deterministic_false.Not_deterministic ->
        for_rel ctx seen closure rules dep_rel_id)
  | Il.Ast.RulePr (dep_rel_id, _ :: _, _, _) ->
    blocked
      ("parameterized RulePr premise for relation `"
       ^ dep_rel_id.it
       ^ "` has no source-complete false support")
  | Il.Ast.LetPr _ ->
    blocked "LetPr false/no-hit support is not source-complete"
  | Il.Ast.ElsePr ->
    blocked "ElsePr nested inside truth refutation is not supported"
  | Il.Ast.IterPr _ ->
    blocked "IterPr false/no-hit support is not source-complete"
  | Il.Ast.NegPr _ ->
    blocked "NegPr false/no-hit support is not source-complete"

and rule ctx ~allow_self seen closure rules rel_id source_rule =
  match source_rule.Analysis.Function_graph.prems with
  | [] -> Supported
  | prems ->
    prems
    |> List.map (premise ctx ~allow_self seen closure rules rel_id)
    |> all

and finite_transitive ctx seen closure rules rel_id domain =
  match Runtime_witness_domain.prepare domain with
  | Error blockers ->
    Blocked
      (blockers
       |> List.map (fun blocker -> blocker.Runtime_witness_domain.reason))
  | Ok _plan ->
    let transitive_rule = domain.Runtime_witness_proof.transitive.rule in
    let local_rules =
      local_relation_rules rel_id rules
      |> List.filter (fun source_rule ->
        not (same_source_rule transitive_rule source_rule))
    in
    (match local_rules with
    | [] ->
      blocked
        ("relation `" ^ rel_id ^ "` has no local source rules to refute")
    | local_rules ->
      local_rules
      |> List.map (fun source_rule ->
        match rule ctx ~allow_self:true seen closure rules rel_id source_rule with
        | Supported -> Supported
        | Blocked blockers ->
          Blocked
            (List.map
               (fun blocker ->
                 rule_text rel_id source_rule ^ ": " ^ blocker)
               blockers))
      |> all)

let check_truth_request ctx truth_request =
  match truth_request.Runtime_truth_search_helper.recursion with
  | Runtime_truth_search_helper.Acyclic ->
    acyclic
      ctx
      []
      truth_request.closure
      truth_request.rules
      truth_request.rel_id
  | Runtime_truth_search_helper.Target_guided_self target ->
    if target_guided_seed_is_functional_for_truth_request truth_request target then
      target_guided
        ctx
        []
        truth_request.closure
        truth_request.rules
        target
    else
      blocked
        "target-guided truth search seed is not functional, so false/no-hit cannot be delegated soundly"
  | Runtime_truth_search_helper.Finite_transitive domain ->
    finite_transitive
      ctx
      []
      truth_request.closure
      truth_request.rules
      truth_request.rel_id
      domain
  | Runtime_truth_search_helper.Recursive _ ->
    blocked
      "runtime truth recursion is recursive without a finite no-hit proof"

let check ctx request =
  check_truth_request ctx request.Runtime_truth_decision_helper.truth_request
