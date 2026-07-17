open Il.Ast
open Util.Source


type binding_diagnostic =
  { constructor : string
  ; reason : string
  ; suggestion : string
  ; blocked_witness_source_ids : string list
  }

type local_existential_plan =
  | Search_ready of
      { rel_id : string
      ; witness_source_id : string
      ; targets : Runtime_search_helper.target list
      ; dependent_source_ids : string list
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      ; witness_space : Runtime_witness_space.t
      }
  | Search_blocked of
      { rel_id : string
      ; witness_source_id : string
      ; targets : Runtime_search_helper.target list
      ; dependent_source_ids : string list
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      ; blockers : Analysis.Function_graph.runtime_search_blocker list
      ; witness_blockers : Runtime_witness_space.blocker list
      }

type truth_plan =
  | Truth_not_needed
  | Truth_ready of
      { rel_id : string
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      }
  | Truth_blocked of
      { rel_id : string
      ; closure : string list
      ; rules : Analysis.Function_graph.runtime_search_rule list
      ; blockers : Analysis.Function_graph.runtime_search_blocker list
      }

let runtime_predicate_premise_shape ctx = function
  | { it = RulePr (_rel_id, _ :: _, _mixop, _); _ } -> false
  | { it = RulePr (rel_id, [], mixop, _); _ } ->
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | None -> false
    | Some relation ->
      let relation_shape = Relation_shape.of_relation relation in
      let local_kind = Analysis.Relation_graph.classify_mixop mixop in
      local_kind = relation_shape.Relation_shape.marker
      && Analysis.Relation_graph.eq_mixop relation.mixop mixop
      &&
      match relation_shape.Relation_shape.decision with
      | Relation_shape.Runtime_predicate _ -> true
      | Relation_shape.Static_validation _ ->
        Analysis.Function_graph.relation_is_runtime_demanded
          (Context.function_graph ctx)
          rel_id.it
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> false)
  | _ -> false

let premise_uses_source source_id prem =
  List.mem source_id (Source_free_vars.prem_ids prem)

let runtime_predicate_consumes_source ctx source_id prem =
  runtime_predicate_premise_shape ctx prem && premise_uses_source source_id prem

let target_of_premise prem =
  match prem.it with
  | RulePr (rel_id, [], _, _) ->
    { Runtime_search_helper.target_rel_id = Some rel_id.it
    ; target_source = Some (Il.Print.string_of_prem prem)
    ; target_premise = prem
    }
  | _ ->
    { Runtime_search_helper.target_rel_id = None
    ; target_source = Some (Il.Print.string_of_prem prem)
    ; target_premise = prem
    }

let witness_space_target_of_target target =
  { Runtime_witness_space.target_rel_id = target.Runtime_search_helper.target_rel_id
  ; target_source = target.target_source
  ; target_premise = target.target_premise
  }

let witness_space_targets targets =
  targets |> List.map witness_space_target_of_target

let witness_runtime_targets ctx witness future_prems =
  let rec loop targets = function
    | [] -> Some (List.rev targets)
    | prem :: prems when not (premise_uses_source witness prem) ->
      loop targets prems
    | prem :: prems when runtime_predicate_consumes_source ctx witness prem ->
      loop (target_of_premise prem :: targets) prems
    | _ :: _ -> None
  in
  match loop [] future_prems with
  | Some (_ :: _ as targets) -> Some targets
  | Some [] | None -> None

let local_existential_candidate ctx missing_sources escape_source_ids future_prems =
  match missing_sources with
  | [ witness ] ->
    (not (List.mem witness escape_source_ids))
    && Option.is_some (witness_runtime_targets ctx witness future_prems)
  | _ -> false

let format_search_list ?(limit = 8) values =
  let rec take n values =
    match n, values with
    | 0, rest -> [], List.length rest
    | _, [] -> [], 0
    | n, value :: rest ->
      let kept, omitted = take (n - 1) rest in
      value :: kept, omitted
  in
  let kept, omitted = take limit values in
  let rendered = String.concat "; " kept in
  if omitted = 0 then rendered
  else if rendered = "" then Printf.sprintf "... and %d more" omitted
  else Printf.sprintf "%s; ... and %d more" rendered omitted

let format_blocker (blocker : Analysis.Function_graph.runtime_search_blocker) =
  let rule =
    match blocker.Analysis.Function_graph.rule_id with
    | None -> ""
    | Some rule_id -> "/" ^ rule_id
  in
  let origin =
    match
      ( blocker.Analysis.Function_graph.premise_origin
      , blocker.Analysis.Function_graph.origin )
    with
    | Some origin, _ | None, Some origin -> " at " ^ Origin.summary origin
    | None, None -> ""
  in
  let premise =
    match
      ( blocker.Analysis.Function_graph.premise_constructor
      , blocker.Analysis.Function_graph.premise_source_echo )
    with
    | None, None -> ""
    | Some constructor, None -> " via " ^ constructor
    | None, Some source -> " via premise `" ^ source ^ "`"
    | Some constructor, Some source -> " via " ^ constructor ^ " `" ^ source ^ "`"
  in
  Printf.sprintf
    "%s%s%s%s [%s]: %s"
    blocker.Analysis.Function_graph.relation_id
    rule
    origin
    premise
    blocker.Analysis.Function_graph.constructor
    blocker.Analysis.Function_graph.reason

let format_witness_blocker (blocker : Runtime_witness_space.blocker) =
  let rule =
    match blocker.Runtime_witness_space.rule_id with
    | None -> ""
    | Some rule_id -> "/" ^ rule_id
  in
  let origin =
    match blocker.origin with
    | Some origin -> " at " ^ Origin.summary origin
    | None -> ""
  in
  Printf.sprintf
    "%s%s%s [%s]: %s"
    blocker.relation_id
    rule
    origin
    blocker.constructor
    blocker.reason

let target_rel_ids targets =
  targets
  |> List.filter_map (fun target -> target.Runtime_search_helper.target_rel_id)
  |> List.sort_uniq String.compare

let target_rel_text targets =
  match target_rel_ids targets with
  | [] -> ""
  | [ target ] -> " consumed by target predicate `" ^ target ^ "`"
  | targets ->
    " consumed by target predicates `"
    ^ String.concat "`, `" targets
    ^ "`"

let rec premise_edges acc prem =
  match prem.it with
  | RulePr (id, [], _, _) -> id.it :: acc
  | RulePr (_, _ :: _, _, _) -> acc
  | IterPr (body, _) | NegPr body -> premise_edges acc body
  | IfPr _ | LetPr _ | ElsePr -> acc

let rule_edges (rule : Analysis.Function_graph.runtime_search_rule) =
  rule.prems
  |> List.fold_left premise_edges []
  |> List.sort_uniq String.compare

let relation_edges closure rule =
  rule_edges rule |> List.filter (fun id -> List.mem id closure)

let graph_edges closure rules =
  let add_rule edges rule =
    let relation_id = rule.Analysis.Function_graph.relation_id in
    let existing = Option.value ~default:[] (List.assoc_opt relation_id edges) in
    let next =
      relation_edges closure rule @ existing |> List.sort_uniq String.compare
    in
    (relation_id, next) :: List.remove_assoc relation_id edges
  in
  rules |> List.fold_left add_rule []

let find_cycle closure rules =
  let edges = graph_edges closure rules in
  let successors id = Option.value ~default:[] (List.assoc_opt id edges) in
  let rec visit path id =
    if List.mem id path then
      Some (List.rev (id :: path))
    else
      successors id |> List.find_map (visit (id :: path))
  in
  closure |> List.find_map (visit [])

let truth_recursion rel_id closure rules =
  match
    Runtime_witness_space.proof_for_truth_relation
      ~rel_id
      ~closure
      ~rules
  with
  | Ok proof ->
    (match Runtime_witness_proof.recursion proof with
    | Runtime_witness_proof.Acyclic -> Runtime_truth_search_helper.Acyclic
    | Runtime_witness_proof.Finite_transitive domain ->
      Runtime_truth_search_helper.Finite_transitive domain
    | Runtime_witness_proof.Target_guided_self target ->
      Runtime_truth_search_helper.Target_guided_self target)
  | Error _ ->
    (match find_cycle closure rules with
    | None -> Runtime_truth_search_helper.Acyclic
    | Some cycle -> Runtime_truth_search_helper.Recursive cycle)

let truth_search_needed rel_id closure rules =
  match truth_recursion rel_id closure rules with
  | Runtime_truth_search_helper.Acyclic ->
    Option.is_some (find_cycle closure rules)
  | Runtime_truth_search_helper.Finite_transitive _
  | Runtime_truth_search_helper.Target_guided_self _
  | Runtime_truth_search_helper.Recursive _ -> true

let truth_recursion_ready_for_call_site = function
  | Runtime_truth_search_helper.Acyclic -> true
  | Finite_transitive _ | Target_guided_self _ | Recursive _ -> false

let witness_space_ready_for_call_site witness_space =
  match Runtime_witness_space.proof witness_space |> Runtime_witness_proof.recursion with
  | Runtime_witness_proof.Acyclic -> true
  | Finite_transitive _ | Target_guided_self _ -> true

let blocker_of_unready_witness_space rel_id witness_space =
  match Runtime_witness_space.proof witness_space |> Runtime_witness_proof.recursion with
  | Runtime_witness_proof.Acyclic ->
    { Runtime_witness_space.relation_id = rel_id
    ; rule_id = None
    ; origin = None
    ; constructor = "RuntimeWitnessSpace/call-site-readiness-invariant"
    ; reason =
        "acyclic runtime witness search reached the non-ready call-site branch"
    ; suggestion =
        "Keep this Unsupported and fix witness-space readiness classification before emitting helper calls"
    ; source_echo = None
    }
  | Finite_transitive domain ->
    let rule = domain.Runtime_witness_proof.transitive.rule in
    { Runtime_witness_space.relation_id = rule.relation_id
    ; rule_id = rule.rule_id
    ; origin = Some rule.origin
    ; constructor =
        "RuntimeWitnessSpace/finite-transitive-materializer-not-ready"
    ; reason =
        "runtime witness search has a source finite-transitive proof, but finite-domain candidates, fuel, and visited-state helper rules are not connected yet"
    ; suggestion =
        "Materialize the closed-world candidate domain and finite transitive rewrite helper atomically before connecting this search at call sites"
    ; source_echo = rule.source_echo
    }
  | Target_guided_self target ->
    let rule = target.Runtime_witness_proof.rule in
    { Runtime_witness_space.relation_id = rule.relation_id
    ; rule_id = rule.rule_id
    ; origin = Some rule.origin
    ; constructor =
        "RuntimeWitnessSpace/target-guided-self-materializer-not-ready"
    ; reason =
        "runtime witness search has a source target-guided recursive rule through target predicate `"
        ^ target.target_rel_id
        ^ "`, but the target-guided rewrite materializer is not connected yet"
    ; suggestion =
        "Materialize the target-guided search rule and its dependent target truth helper atomically before emitting this local-existential search"
    ; source_echo = rule.source_echo
    }

let truth_plan ctx rel_id =
  match
    Analysis.Function_graph.runtime_predicate_truth_plan
      (Context.function_graph ctx)
      rel_id
  with
  | Runtime_search_no_shape_blockers { closure; rules }
    when truth_search_needed rel_id closure rules ->
    Truth_ready { rel_id; closure; rules }
  | Runtime_search_blocked_plan { closure; rules; blockers }
    when truth_search_needed rel_id closure rules ->
    Truth_blocked { rel_id; closure; rules; blockers }
  | Runtime_search_no_shape_blockers _ | Runtime_search_blocked_plan _ ->
    Truth_not_needed

let truth_helper_request ~input_terms ~input_sorts = function
  | Truth_ready { rel_id; closure; rules } ->
    let recursion = truth_recursion rel_id closure rules in
    if truth_recursion_ready_for_call_site recursion then
      Some
        { Runtime_truth_search_helper.rel_id
        ; input_terms
        ; input_sorts
        ; recursion
        ; closure
        ; rules
        }
    else
      None
  | Truth_not_needed | Truth_blocked _ -> None

let runtime_constructor ctx typ mixop arity =
  match
    Typcase_constructor.resolve_emitted ctx typ mixop ~arity
  with
  | Typcase_constructor.Found resolution ->
    Some resolution.Typcase_constructor.registry_entry
  | Typcase_constructor.Missing
  | Typcase_constructor.Blocked _
  | Typcase_constructor.Ambiguous _ -> None

let truth_worklist_request ctx ~rel_id ~input_terms ~input_sorts =
  let origin =
    Origin.synthetic ~ast_constructor:"RuntimeTruthScc" "premise-schedule"
  in
  let total_value ~bound exp =
    Runtime_truth_total_equality.source_total ctx ~bound origin exp
  in
  let total_value_with_facts ~facts ~bound exp =
    Runtime_truth_total_equality.source_total ~facts ctx ~bound origin exp
  in
  let zero_or_one_value ~bound exp =
    Runtime_truth_total_equality.source_zero_or_one ctx ~bound origin exp
  in
  let plan =
    Runtime_truth_scc.plan
      ~total_value ~zero_or_one_value ~total_value_with_facts
      ~constructors:(Context.constructors ctx)
      ~resolve_constructor:(runtime_constructor ctx)
      (Context.function_graph ctx) rel_id
  in
  let rec premise_ready ~successor = function
    | Runtime_truth_scc.Finite_rule_call _
    | Finite_domain_call _
    | Deterministic_total _
    | Externally_validated _
    | Source_boolean _ -> true
    | Deterministic_binding_iter _ -> true
    | Finite_iter { body; _ } -> List.for_all (premise_ready ~successor) body
    | Finite_successor_call _ -> successor
  in
  let finite_successor_rule (rule : Runtime_truth_scc.rule) =
    let source = rule.source in
    let source_rule =
      { Runtime_witness_proof.identity = source.identity
      ; relation_id = source.relation_id
      ; rule_id = source.rule_id
      ; origin = source.origin
      ; source_echo = source.source_echo
      ; head = source.head
      ; prems = source.prems
      }
    in
    Option.is_some (Runtime_witness_proof.target_chain source_rule)
    || Option.is_some (Runtime_witness_proof.transitive_domain source_rule)
  in
  let ready =
    Runtime_truth_scc.complete plan
    && List.for_all
         (fun scc ->
           List.for_all
             (fun rule ->
               List.for_all
                 (premise_ready ~successor:(finite_successor_rule rule))
                 rule.Runtime_truth_scc.premises)
             scc.Runtime_truth_scc.rules)
         plan.Runtime_truth_scc.sccs
  in
  if not ready then None
  else
    Some
      { Runtime_truth_worklist_helper.relation_id = rel_id
      ; specialization =
          String.concat "," (List.map Maude_ir.sort_name input_sorts)
      ; input_terms
      ; input_sorts
      ; phase = Runtime_truth_scc.Goal
      ; mode = Runtime_truth_worklist_helper.Prove
      ; plan
      }

let truth_worklist_blockers ctx rel_id =
  let origin =
    Origin.synthetic ~ast_constructor:"RuntimeTruthScc" "premise-schedule"
  in
  let total_value ~bound exp =
    Runtime_truth_total_equality.source_total ctx ~bound origin exp
  in
  let total_value_with_facts ~facts ~bound exp =
    Runtime_truth_total_equality.source_total ~facts ctx ~bound origin exp
  in
  let zero_or_one_value ~bound exp =
    Runtime_truth_total_equality.source_zero_or_one ctx ~bound origin exp
  in
  let plan =
    Runtime_truth_scc.plan
      ~total_value ~zero_or_one_value ~total_value_with_facts
      ~constructors:(Context.constructors ctx)
      ~resolve_constructor:(runtime_constructor ctx)
      (Context.function_graph ctx) rel_id
  in
  plan.blockers
  |> List.map (fun (blocker : Runtime_truth_scc.blocker) ->
    let rule = Option.fold ~none:"" ~some:(fun id -> "/" ^ id) blocker.rule_id in
    blocker.relation_id ^ rule ^ " [" ^ blocker.constructor ^ "]: " ^ blocker.reason)

let truth_diagnostic ctx rel_id =
  match truth_plan ctx rel_id with
  | Truth_not_needed -> None
  | Truth_ready { closure; _ } ->
    Some
      { constructor =
          "Premise/RulePr/runtime-predicate/truth-search-helper-unimplemented"
      ; reason =
          "This runtime predicate is source-recursive/transitive, so a Bool condition could observe an incomplete predicate; it needs a rewrite-backed truth-search helper. Search closure: "
          ^ String.concat " -> " closure
      ; suggestion =
          "Register and materialize a source-complete runtime truth-search helper before using this predicate as a condition; do not emit partial Bool ceq branches"
      ; blocked_witness_source_ids = []
      }
  | Truth_blocked { closure; blockers; _ } ->
    let blockers = List.map format_blocker blockers in
    Some
      { constructor =
          "Premise/RulePr/runtime-predicate/truth-search-blocked"
      ; reason =
          "This runtime predicate is source-recursive/transitive, but its truth-search closure is not source-complete yet. Search closure: "
          ^ String.concat " -> " closure
          ^ ". Search blockers: "
          ^ format_search_list blockers
      ; suggestion =
          "Keep this predicate Unsupported until every source RuleD in the truth-search closure can be represented by rewrite-backed helper rules"
      ; blocked_witness_source_ids = []
      }

let local_existential_plan ctx rel_id ~missing_sources ~escape_source_ids ~future_prems =
  if not (local_existential_candidate ctx missing_sources escape_source_ids future_prems) then
    None
  else
    match missing_sources with
    | [] | _ :: _ :: _ -> None
    | [ witness_source_id ] ->
      let targets =
        Option.value
          ~default:[]
          (witness_runtime_targets ctx witness_source_id future_prems)
      in
      let dependent_source_ids =
        targets
        |> List.concat_map (fun target ->
          Source_free_vars.prem_ids target.Runtime_search_helper.target_premise)
        |> List.sort_uniq String.compare
      in
      match
        Analysis.Function_graph.runtime_predicate_search_plan
          (Context.function_graph ctx)
          rel_id
      with
      | Analysis.Function_graph.Runtime_search_no_shape_blockers { closure; rules } ->
        (match
           Runtime_witness_space.prove
             ~rel_id
             ~witness_source_id
             ~targets:(witness_space_targets targets)
             ~closure
             ~rules
         with
        | Ok witness_space when witness_space_ready_for_call_site witness_space ->
          Some
            (Search_ready
               { rel_id
               ; witness_source_id
               ; targets
               ; dependent_source_ids
               ; closure
               ; rules
               ; witness_space
               })
        | Ok _witness_space ->
          Some
            (Search_blocked
               { rel_id
               ; witness_source_id
               ; targets
               ; dependent_source_ids
               ; closure
               ; rules
               ; blockers = []
               ; witness_blockers =
                   [ blocker_of_unready_witness_space rel_id _witness_space ]
               })
        | Error witness_blockers ->
          Some
            (Search_blocked
               { rel_id
               ; witness_source_id
               ; targets
               ; dependent_source_ids
               ; closure
               ; rules
               ; blockers = []
               ; witness_blockers
               }))
      | Analysis.Function_graph.Runtime_search_blocked_plan { closure; rules; blockers } ->
        Some
          (Search_blocked
             { rel_id
             ; witness_source_id
             ; targets
             ; dependent_source_ids
             ; closure
             ; rules
             ; blockers
             ; witness_blockers = []
             })

let helper_request
    ~input_terms
    ~input_sorts
    ~guides
    ~witness_index
    ~witness_term
    ~witness_sort
  =
  function
  | Search_ready
      { rel_id
      ; witness_source_id
      ; targets
      ; dependent_source_ids
      ; closure
      ; rules
      ; witness_space
      } ->
    Some
      { Runtime_search_helper.rel_id = rel_id
      ; witness_source_id
      ; targets
      ; guides
      ; input_terms
      ; input_sorts
      ; witness_index
      ; witness_term
      ; witness_sort
      ; dependent_source_ids
      ; closure
      ; rules
      ; witness_space
      }
  | Search_blocked _ -> None

let binding_diagnostic ctx rel_id ~missing_sources ~escape_source_ids ~future_prems =
  match
    local_existential_plan ctx rel_id ~missing_sources ~escape_source_ids ~future_prems
  with
  | None -> None
  | Some (Search_ready { witness_source_id; targets; closure; _ }) ->
      Some
        { constructor =
            "Premise/RulePr/runtime-predicate/local-existential-helper-unimplemented"
        ; reason =
            "This RulePr has unbound argument(s) that are used by later premises in the same source block, and the referenced relation has no currently known shape blockers for a future source-derived search helper: "
            ^ witness_source_id
            ^ target_rel_text targets
            ^ ". Search closure: "
            ^ String.concat " -> " closure
        ; suggestion =
            "Lower this only after implementing and validating the rewrite-backed local-existential helper materializer for every source RuleD in the closure; do not encode it as a Bool predicate or deterministic witness function"
        ; blocked_witness_source_ids = [ witness_source_id ]
        }
  | Some (Search_blocked
            { witness_source_id; targets; closure; blockers; witness_blockers; _ }) ->
      let blockers =
        List.map format_blocker blockers
        @ List.map format_witness_blocker witness_blockers
      in
      Some
        { constructor =
            "Premise/RulePr/runtime-predicate/local-existential-search-blocked"
        ; reason =
            "This RulePr has unbound argument(s) used by later premises, but the referenced relation cannot yet be emitted as a source-complete search helper: "
            ^ witness_source_id
            ^ target_rel_text targets
            ^ ". Search closure: "
            ^ String.concat " -> " closure
            ^ ". Search blockers: "
            ^ format_search_list blockers
        ; suggestion =
            "Keep this Unsupported until every source RuleD of the referenced predicate relation can be represented by a rewrite-backed search relation; partial search helpers are unsound"
        ; blocked_witness_source_ids = [ witness_source_id ]
        }
