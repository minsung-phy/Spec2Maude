open Maude_ir
open Runtime_truth_worklist_core
open Runtime_truth_worklist_positive

type item = Runtime_truth_worklist_core.item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_worklist_helper.request
  }

type complete =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type result =
  | Complete_result of complete
  | Blocked_result of Diagnostics.t list

let complete_statements complete = complete.statements
let complete_diagnostics complete = complete.diagnostics

let complete_result statements diagnostics =
  if List.exists Diagnostics.is_fatal diagnostics then
    Blocked_result diagnostics
  else
    Complete_result { statements; diagnostics }

let declaration statement =
  match statement.node with
  | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ -> true
  | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ -> false

let declarations_first statements =
  let declarations, definitions = List.partition declaration statements in
  declarations @ definitions

let public_rules item root =
  let invocation = Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request in
  let history = Const "eps" in
  let formals, _ = public_vars item in
  let lhs = public_lhs item in
  [ generated item item.origin
      (crl ~label:(item.name ^ "-proved") lhs invocation.proved_rhs
         [ RewriteCond
             (App (prove_op item root.id, formals @ [ history ]),
              invocation.proved_rhs) ])
  ]
  @ match item.request.mode with
    | Runtime_truth_worklist_helper.Prove -> []
    | Decide ->
      [ generated item item.origin
          (crl ~label:(item.name ^ "-refuted") lhs invocation.refuted_rhs
             [ RewriteCond
                 (App (refute_op item root.id, formals @ [ history ]),
                  invocation.refuted_rhs) ]) ]

(* Positive RuleD clauses are Horn alternatives, so searching Ordinary before
   Transitive preserves their least fixed point; admission still requires the
   finite source-complete worklist certificate. *)
let materialize_complete ctx item relations =
  match find_relation relations item.request.relation_id with
  | None ->
    Blocked_result [ diagnostic ctx item item.origin
        "RuntimeTruthWorklist/root-signature" "root relation has no complete Maude carrier signature"
        "Keep this query Unsupported until every root component has a carrier sort" (Some (Runtime_truth_worklist_helper.reason item.request)) ]
  | Some root ->
    let indexed = ref 0 in
    let relation_results = relations |> List.map (fun relation ->
      let rules = relation.rules |> List.map (fun rule -> incr indexed; !indexed, rule) in
      let seed_statements, seed_diagnostics =
        match relation.rules |> List.find_map target_chain with
        | None -> [], []
        | Some target -> seed_rules ctx item relations relation rules target
      in
      let positives = rules |> List.map (fun (index, rule) ->
        Positive_rule.lower ctx item relations relation index rule) in
      let refuters =
        match item.request.mode with
        | Runtime_truth_worklist_helper.Prove -> []
        | Decide ->
          rules |> List.map (fun (index, rule) ->
            Runtime_truth_worklist_refutation.lower_rule
              ctx item relations relation index rule)
      in
      let statements = relation_surface item relation
        @ positive_dispatcher item relation
        @ seed_statements
        @ List.concat_map (fun (index, _) -> rule_surface item relation index) rules
        @ List.concat_map fst positives @ List.concat_map fst refuters
        @ (match item.request.mode with
           | Runtime_truth_worklist_helper.Prove -> []
           | Decide ->
             Runtime_truth_worklist_refutation.solver item relation rules)
      in
      let diagnostics =
        seed_diagnostics @ List.concat_map snd positives @ List.concat_map snd refuters
      in
      statements, diagnostics)
    in
    let diagnostics = List.concat_map snd relation_results in
    if List.exists Diagnostics.is_fatal diagnostics then Blocked_result diagnostics
    else
      let statements =
        helper_surface item @ positive_phase_surface item
        @ List.concat_map fst relation_results @ public_rules item root
        |> List.fold_left
             (fun statements statement ->
               if List.exists (( = ) statement) statements then statements
               else statement :: statements)
             []
        |> List.rev
        |> declarations_first
      in
      complete_result statements diagnostics

let target_chain_decision_diagnostics ctx item =
  match item.request.mode with
  | Runtime_truth_worklist_helper.Prove -> []
  | Decide ->
    item.request.plan.Runtime_truth_scc.sccs
    |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
    |> List.filter_map target_chain
    |> List.map (fun target ->
      let source = target.Runtime_witness_proof.rule in
      let identity =
        source.relation_id ^ "/"
        ^ Option.value ~default:"_" source.rule_id
      in
      diagnostic ctx item source.origin
        "RuntimeTruthWorklist/target-chain/decision-unsupported"
        ("source target-chain RuleD `" ^ identity
         ^ "` has no concise source-complete universal refutation certificate; one failing seed witness cannot establish false")
        "Use Prove mode, or implement and audit a finite certificate that refutes every source-complete seed witness before admitting Decide"
        source.source_echo)

let materialize_item ctx item =
  let planner_diagnostics = List.map (planner_diagnostic ctx item) item.request.plan.blockers in
  let domain_diagnostics = successor_domain_diagnostics ctx item in
  let target_chain_diagnostics = target_chain_decision_diagnostics ctx item in
  if planner_diagnostics <> [] || domain_diagnostics <> []
     || target_chain_diagnostics <> []
  then
    Blocked_result
      (planner_diagnostics @ domain_diagnostics @ target_chain_diagnostics)
  else
    materialize_complete ctx item (relations item.request.plan)

let materialize ctx items =
  let stage = Context.begin_stage ctx in
  let staged = Context.staged stage in
  let results = List.map (materialize_item staged) items in
  let diagnostics =
    results
    |> List.concat_map (function
      | Complete_result complete -> complete.diagnostics
      | Blocked_result diagnostics -> diagnostics)
  in
  if List.exists (function Blocked_result _ -> true | Complete_result _ -> false) results then
    Blocked_result diagnostics
  else
    let statements =
      results
      |> List.concat_map (function
        | Complete_result complete -> complete.statements
        | Blocked_result _ -> [])
    in
    let result = complete_result (declarations_first statements) diagnostics in
    (match result with
    | Complete_result _ -> Context.commit_stage stage
    | Blocked_result _ -> ());
    result
