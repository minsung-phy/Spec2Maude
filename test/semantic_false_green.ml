open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let var text = VarE (id text) $$ region % nat_typ
let origin name = Origin.synthetic ~ast_constructor:"Regression" name
let mixop = Xl.Mixop.Arg ()

let source_rule_identity ?(source_ordinal = 1) ?(source_rule_index = 0) relation_id =
  Source_rule_identity.relation ~source_id:relation_id ~source_ordinal
  |> Source_rule_identity.rule ~source_rule_index

let contains text fragment =
  let text_len = String.length text in
  let fragment_len = String.length fragment in
  let rec loop index =
    index + fragment_len <= text_len
    && (String.sub text index fragment_len = fragment || loop (index + 1))
  in
  fragment_len = 0 || loop 0

let complete_premise label = function
  | Premise_result.Complete result -> result
  | Blocked diagnostics | Deferred (_, diagnostics) ->
    failwith
      (label ^ " premise translation was blocked: "
       ^ Diagnostics.render_all diagnostics)

let predicate_mixop =
  let marker = Xl.Atom.Turnstile $$ region % Xl.Atom.info "regression" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let subtyping_mixop =
  let turnstile = Xl.Atom.Turnstile $$ region % Xl.Atom.info "regression" in
  let sub = Xl.Atom.Sub $$ region % Xl.Atom.info "regression" in
  Xl.Mixop.Seq
    [ Xl.Mixop.Arg (); Xl.Mixop.Atom turnstile; Xl.Mixop.Arg ()
    ; Xl.Mixop.Atom sub; Xl.Mixop.Arg ()
    ]

let fixed_literal_predicate_mixop =
  let marker = Xl.Atom.Turnstile $$ region % Xl.Atom.info "regression" in
  let fixed = Xl.Atom.Atom "PROOF" $$ region % Xl.Atom.info "regression" in
  Xl.Mixop.Seq
    [ Xl.Mixop.Arg ()
    ; Xl.Mixop.Atom marker
    ; Xl.Mixop.Atom fixed
    ; Xl.Mixop.Arg ()
    ]

let execution_mixop =
  let marker = Xl.Atom.SqArrow $$ region % Xl.Atom.info "regression" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let deterministic_mixop =
  let marker = Xl.Atom.Approx $$ region % Xl.Atom.info "regression" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let relation
    ?(runtime_demanded = false)
    ?(external_validation_shape = false)
    id
    rules
  =
  { Runtime_predicate_closure.id
  ; origin = origin id
  ; source_params = []
  ; kind = Predicate_candidate
  ; mixop
  ; result = nat_typ
  ; rules
  ; runtime_demanded
  ; external_validation_shape
  }

let validation_dependency_rule result_id =
  let premise = RulePr (id "validation", [], mixop, var result_id) $ region in
  { Runtime_predicate_closure.identity = source_rule_identity "consumer"
  ; rule_id = Some "ok-dependency"
  ; origin = origin "ok-dependency"
  ; source_echo = None
  ; binds = []
  ; mixop
  ; head = var "x"
  ; prems = [ premise ]
  }

let closure_plan
    ?(result_id = "accepted")
    ?(external_validation_shape = false)
    runtime_demanded
  =
  let relations =
    [ "consumer", relation "consumer" (Some [ validation_dependency_rule result_id ])
    ; ( "validation"
      , relation
          ~runtime_demanded
          ~external_validation_shape
          "validation" None )
    ]
  in
  let graph =
    Runtime_predicate_closure.make
      ~find_relation:(fun id -> List.assoc_opt id relations)
      ~dependencies:(fun _ -> [])
      ~mixop_equal:Il.Eq.eq_mixop
  in
  Runtime_predicate_closure.plan graph Truth_helper "consumer"

let test_external_validation_dependency () =
  (match closure_plan ~result_id:"alpha_result" false with
  | Runtime_predicate_closure.Complete _ -> ()
  | Blocked _ -> failwith "validation-only structural dependency was not discharged");
  (match closure_plan ~result_id:"renamed_result" false with
  | Runtime_predicate_closure.Complete _ -> ()
  | Blocked _ -> failwith "validation discharge changed under alpha-renaming");
  (match closure_plan ~result_id:"renamed_result" true with
  | Runtime_predicate_closure.Blocked { closure; _ }
    when List.mem "validation" closure -> ()
  | Complete _ ->
    failwith "runtime-demanded structural dependency was falsely classified as external"
  | Blocked _ -> failwith "runtime-demanded structural dependency was not in the closure");
  List.iter
    (fun result_id ->
      match
        closure_plan ~result_id ~external_validation_shape:true true
      with
      | Runtime_predicate_closure.Blocked { closure; _ }
        when List.mem "validation" closure -> ()
      | Complete _ ->
        failwith
          "runtime-demanded validation was discharged from a marker without an explicit ingress escape certificate"
      | Blocked _ ->
        failwith "runtime-demanded validation marker lost its retained dependency")
    [ "first_name"; "alpha_name" ]

let test_scc_fixed_literal_runtime_guard_retained () =
  let relation_typ =
    TupT [ id "left", nat_typ; id "right", nat_typ ] $ region
  in
  let x = var "fixed_literal_input" in
  let head = TupE [ x; x ] $$ region % relation_typ in
  let validation_rule =
    RuleD
      (id "fixed-literal-fact", [], fixed_literal_predicate_mixop, head, [])
    $ region
  in
  let validation =
    RelD
      ( id "fixed_literal_validation"
      , []
      , fixed_literal_predicate_mixop
      , relation_typ
      , [ validation_rule ] )
    $ region
  in
  let validation_premise =
    RulePr
      ( id "fixed_literal_validation"
      , []
      , fixed_literal_predicate_mixop
      , head )
    $ region
  in
  let consumer_rule =
    RuleD
      ( id "fixed-literal-consumer"
      , []
      , predicate_mixop
      , head
      , [ validation_premise ] )
    $ region
  in
  let consumer =
    RelD
      ( id "fixed_literal_consumer"
      , []
      , predicate_mixop
      , relation_typ
      , [ consumer_rule ] )
    $ region
  in
  let seed_premise =
    RulePr
      ( id "fixed_literal_consumer"
      , []
      , predicate_mixop
      , TupE [ var "seed"; var "seed" ] $$ region % relation_typ )
    $ region
  in
  let seed_rule =
    RuleD
      ( id "fixed-literal-runtime-seed"
      , []
      , execution_mixop
      , var "seed"
      , [ seed_premise ] )
    $ region
  in
  let seed =
    RelD
      ( id "fixed_literal_runtime_seed"
      , []
      , execution_mixop
      , nat_typ
      , [ seed_rule ] )
    $ region
  in
  let script = [ validation; consumer; seed ] in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let plan =
    Runtime_truth_scc.plan
      (Context.function_graph ctx)
      "fixed_literal_consumer"
  in
  let retained =
    plan.sccs
    |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
    |> List.exists (fun rule ->
      match rule.Runtime_truth_scc.premises with
      | [ Runtime_truth_scc.Finite_rule_call
            { relation_id = "fixed_literal_validation"; _ } ] -> true
      | _ -> false)
  in
  if not retained then
    failwith
      "all-bound fixed-literal runtime premise was erased without an ingress certificate";
  let helper_name = "FixedLiteralIngressAudit" in
  let request =
    { Runtime_truth_worklist_helper.relation_id = "fixed_literal_consumer"
    ; specialization = "nat,nat"
    ; input_terms = [ Const "0"; Const "0" ]
    ; input_sorts = [ sort "Nat"; sort "Nat" ]
    ; phase = Runtime_truth_scc.Goal
    ; mode = Runtime_truth_worklist_helper.Prove
    ; plan
    }
  in
  match
    Runtime_truth_worklist_materializer.materialize ctx
      [ { name = helper_name
        ; origin = origin "fixed-literal-ingress-audit"
        ; request
        } ]
  with
  | Runtime_truth_worklist_materializer.Blocked_result diagnostics ->
    failwith
      ("retained fixed-literal runtime premise did not materialize: "
       ^ String.concat "; "
           (List.map (fun diagnostic -> diagnostic.Diagnostics.reason) diagnostics))
  | Complete_result complete ->
    let dependency_op =
      Naming.helper_companion
        ~role:
          ("truth-prove-" ^ Naming.sanitize "fixed_literal_validation")
        helper_name
    in
    let rec term_has_dependency = function
      | App (op, _) when op = dependency_op -> true
      | App (_, args) -> List.exists term_has_dependency args
      | Var _ | Const _ | Qid _ -> false
    in
    let condition_has_dependency = function
      | EqCondition (EqCond (left, right) | MatchCond (left, right))
      | RewriteCond (left, right) ->
        term_has_dependency left || term_has_dependency right
      | EqCondition (BoolCond term | MembershipCond (term, _)) ->
        term_has_dependency term
    in
    let emitted_dependency =
      Runtime_truth_worklist_materializer.complete_statements complete
      |> List.exists (fun statement ->
        match statement.node with
        | Crl (_, _, _, conditions) ->
          List.exists condition_has_dependency conditions
        | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
        | Eq _ | Ceq _ | Rl _ -> false)
    in
    if not emitted_dependency then
      failwith
        "SCC worklist classified the fixed-literal premise but erased its runtime call"

let exists_request =
  { Helper_request.source_shape =
      { prem_source = "exists"
      ; indexed_source = "xs"
      ; source_typ_source = "nat*"
      ; predicate_source = "p(x)"
      }
  ; index_source_id = "x"
  ; helper_head_var = "H"
  ; source_tail_var = "T"
  ; source_element_sort = sort "Nat"
  ; captures = []
  ; body_eq_conditions = [ BoolCond (Const "p") ]
  }

let test_exists_head_and_tail_success () =
  let request =
    { Helper_request.kind = Iter_premise_exists_bool exists_request
    ; reason = "regression"
    ; origin = origin "exists"
    }
  in
  let entry = { Helper_registry.name = "existsTest"; request } in
  let statements =
    Helper_materialize_iter.materialize_iter_premise_exists_bool
      entry exists_request
  in
  let recursive_lhs =
    App ("existsTest", [ App ("_ _", [ Var "H"; Var "T" ]) ])
  in
  let head_success, tail_success =
    statements
    |> List.fold_left (fun (head, tail) generated ->
      match generated.node with
      | Ceq (lhs, Const "true", [ BoolCond (Const "p") ], [])
        when lhs = recursive_lhs -> true, tail
      | Ceq (lhs, Const "true", [ BoolCond (App ("existsTest", [ Var "T" ])) ], [])
        when lhs = recursive_lhs -> head, true
      | _ -> head, tail)
      (false, false)
  in
  if not head_success then failwith "finite exists lacks nonempty head success";
  if not tail_success then failwith "finite exists lacks tail-recursive success"

let test_rewrite_exists_head_and_tail_success () =
  let prem : Helper_request.iter_premise_exists_rule =
    { source_shape = exists_request.source_shape
    ; index_source_id = "x"
    ; helper_head_var = "H"
    ; source_tail_var = "T"
    ; source_element_sort = sort "Nat"
    ; captures = []
    ; body_conditions = [ RewriteCond (App ("truth", [ Var "H" ]), Const "ok") ]
    }
  in
  let request =
    { Helper_request.kind = Iter_premise_exists_rule prem
    ; reason = "regression"
    ; origin = origin "rewrite-exists"
    }
  in
  let entry = { Helper_registry.name = "existsRule"; request } in
  let statements =
    Helper_materialize_iter.materialize_iter_premise_exists_rule entry prem
  in
  let ok = Naming.helper_companion ~role:"premise-exists-ok" entry.name in
  let nonempty = App ("existsRule", [ App ("_ _", [ Var "H"; Var "T" ]) ]) in
  let head, tail =
    statements
    |> List.fold_left (fun (head, tail) generated ->
      match generated.node with
      | Crl (_, lhs, Const result, conditions) when lhs = nonempty && result = ok ->
        ( List.mem (RewriteCond (App ("truth", [ Var "H" ]), Const "ok")) conditions
          || head
        , List.mem (RewriteCond (App ("existsRule", [ Var "T" ]), Const ok)) conditions
          || tail )
      | _ -> head, tail)
      (false, false)
  in
  if not head then failwith "rewrite-backed exists lacks head proof";
  if not tail then failwith "rewrite-backed exists lacks tail proof";
  let raw_bool_call =
    List.exists
      (fun generated ->
        match generated.node with
        | Crl (_, _, _, conditions) ->
          List.exists
            (function
              | EqCondition (BoolCond (App ("truth", _))) -> true
              | _ -> false)
            conditions
        | _ -> false)
      statements
  in
  if raw_bool_call then
    failwith "rewrite-backed indexed exists fell through to a raw Bool relation call";
  if not
       (List.exists
          (fun generated ->
            match generated.node with
            | OpDecl { name = "existsRule"; attrs = [ Frozen [ 1 ] ]; _ } -> true
            | _ -> false)
          statements)
  then failwith "rewrite-backed exists helper input is not frozen"

let rulepr relation components =
  RulePr (id relation, [], mixop, TupE components $$ region % nat_typ) $ region

let rulepr_with relation_mixop relation components =
  RulePr
    (id relation, [], relation_mixop,
     TupE components $$ region % nat_typ)
  $ region

let test_finite_transitive_proof () =
  let c, left, right, witness = var "c", var "left", var "right", var "witness" in
  let source_rule =
    { Runtime_witness_proof.identity = source_rule_identity "relation"
    ; relation_id = "relation"
    ; rule_id = Some "transitive"
    ; origin = origin "finite-transitive"
    ; source_echo = Some "renamed finite transitive source"
    ; head = TupE [ c; left; right ] $$ region % nat_typ
    ; prems =
        [ rulepr "domain" [ c; witness ]
        ; rulepr "relation" [ c; left; witness ]
        ; rulepr "relation" [ c; witness; right ]
        ]
    }
  in
  let transitive =
    match Runtime_witness_proof.transitive_domain source_rule with
    | Some transitive -> transitive
    | None -> failwith "source transitive RulePr shape was not recognized"
  in
  let closure_rule : Runtime_predicate_closure.rule =
    { identity = source_rule.identity
    ; rule_id = Some "transitive"
    ; origin = origin "finite-transitive-cycle"
    ; source_echo = None
    ; binds = []
    ; mixop
    ; head = source_rule.head
    ; prems = source_rule.prems
    }
  in
  let closure_graph =
    Runtime_predicate_closure.make
      ~find_relation:(function
        | "relation" -> Some (relation ~runtime_demanded:true "relation" (Some [ closure_rule ]))
        | _ -> None)
      ~dependencies:(fun _ -> [])
      ~mixop_equal:Il.Eq.eq_mixop
  in
  (match Runtime_predicate_closure.plan closure_graph Truth_helper "relation" with
  | Blocked { blockers; _ }
    when List.exists
           (fun blocker ->
             blocker.Runtime_predicate_closure.constructor
             = "RuntimePredicateClosure/recursive-transitive-cycle")
           blockers ->
    ()
  | Blocked _ -> failwith "transitive truth cycle reported the wrong blocker"
  | Complete _ -> failwith "transitive truth cycle was admitted without an SCC proof");
  let proof = Runtime_witness_proof.closed_world_domain transitive in
  if proof.domain_plan.fuel_measure <> "candidate-domain-length" then
    failwith "finite transitive proof uses an arbitrary fuel measure";
  if not (List.mem "witness" proof.visited_key_source_ids) then
    failwith "finite transitive proof omits the witness from its visited key";
  let malformed =
    Runtime_witness_proof.closed_world_domain
      { transitive with witness_source_id = "renamed_other_witness" }
  in
  (match Runtime_witness_domain.prepare malformed with
  | Error blockers
    when List.exists
           (fun blocker ->
             blocker.Runtime_witness_domain.constructor
             = "RuntimeWitnessDomain/witness-source"
             && blocker.ast_constructor = "VarE"
             && blocker.premise_index = Some 0
             && Option.is_some blocker.premise_context
             && Option.is_some blocker.source_echo)
           blockers -> ()
  | Error _ -> failwith "domain-premise blocker lost its structured source index"
  | Ok _ -> failwith "malformed finite domain was certified");
  match Runtime_witness_domain.prepare proof with
  | Error blockers
    when List.exists
           (fun blocker ->
             blocker.Runtime_witness_domain.constructor
             = "RuntimeWitnessDomain/unproved-successor-closure"
             && blocker.ast_constructor = "RuntimeWitnessDomain"
             && blocker.premise_index = None
             && blocker.relation_id = "relation"
             && blocker.rule_id = Some "transitive"
             && blocker.origin = source_rule.origin
             && blocker.suggestion <> ""
             && Option.is_some blocker.source_echo)
           blockers ->
    ()
  | Error _ -> failwith "transitive witness domain reported the wrong blocker"
  | Ok _ -> failwith "endpoint/closed-head candidates were accepted as a complete domain"

let test_runtime_truth_query_key () =
  let request domain input_terms =
    { Runtime_truth_search_helper.rel_id = "relation"
    ; input_terms
    ; input_sorts = List.map (fun _ -> sort "SpectecTerminal") input_terms
    ; recursion = Finite_transitive domain
    ; closure = [ "relation" ]
    ; rules = []
    }
  in
  let c, left, right, witness = var "c", var "left", var "right", var "witness" in
  let source_rule =
    { Runtime_witness_proof.identity = source_rule_identity "relation"
    ; relation_id = "relation"
    ; rule_id = Some "transitive"
    ; origin = origin "query-key"
    ; source_echo = None
    ; head = TupE [ c; left; right ] $$ region % nat_typ
    ; prems =
        [ rulepr "domain" [ c; witness ]
        ; rulepr "relation" [ c; left; witness ]
        ; rulepr "relation" [ c; witness; right ]
        ]
    }
  in
  let transitive =
    match Runtime_witness_proof.transitive_domain source_rule with
    | Some transitive -> transitive
    | None -> failwith "query-key transitive shape was not recognized"
  in
  let domain = Runtime_witness_proof.closed_world_domain transitive in
  let closed = request domain [ Const "empty-context"; Var "L"; Var "R" ] in
  let other = request domain [ Var "C"; Var "L"; Var "R" ] in
  if Runtime_truth_search_helper.key closed = Runtime_truth_search_helper.key other then
    failwith "runtime truth helper dedup erased the concrete query term";
  let endpoints = request domain [ Const "empty-context"; Const "L1"; Const "R1" ] in
  let other_endpoints = request domain [ Const "empty-context"; Const "L2"; Const "R2" ] in
  if Runtime_truth_search_helper.key endpoints = Runtime_truth_search_helper.key other_endpoints then
    failwith "runtime truth helper dedup erased specialized closed endpoints"

let runtime_script relations seed =
  let seed_rule = rulepr seed [ var "seed"; var "seed" ] in
  let rule = RuleD (id "runtime-seed", [], execution_mixop, var "seed", [ seed_rule ]) $ region in
  let seed_def = RelD (id "runtime_seed", [], execution_mixop, nat_typ, [ rule ]) $ region in
  relations @ [ seed_def ]

let function_graph relations seed =
  runtime_script relations seed
  |> Analysis.Source_index.of_script
  |> Analysis.Function_graph.build

let relation_def name rules =
  RelD (id name, [], predicate_mixop, nat_typ, rules) $ region

let source_rule name head prems =
  RuleD (id name, [], predicate_mixop, head, prems) $ region

let typed_var typ text = VarE (id text) $$ region % typ

let indexed_constructor_graph source_typ =
  let sequence_typ = IterT (nat_typ, List) $ region in
  let context = typed_var source_typ "context" in
  let left, right, index = var "left", var "right", var "index" in
  let tag_typ = VarT (id "tag", []) $ region in
  let tag =
    Xl.Atom.Atom "TAG" $$ region % Xl.Atom.info "regression"
  in
  let constructor = Xl.Mixop.Seq [ Xl.Mixop.Atom tag; Xl.Mixop.Arg () ] in
  let successor = CaseE (constructor, index) $$ region % tag_typ in
  let projected = IdxE (context, index) $$ region % nat_typ in
  let indexed =
    source_rule "indexed-constructor"
      (TupE [ context; left; successor ] $$ region % nat_typ)
      [ rulepr "relation_renamed" [ context; left; projected ] ]
  in
  let witness = var "witness" in
  let transitive =
    source_rule "transitive"
      (TupE [ context; left; right ] $$ region % nat_typ)
      [ rulepr "domain_renamed" [ context; witness ]
      ; rulepr "relation_renamed" [ context; left; witness ]
      ; rulepr "relation_renamed" [ context; witness; right ]
      ]
  in
  function_graph
    [ relation_def "relation_renamed" [ indexed; transitive ] ]
    "relation_renamed",
  sequence_typ

let successor_certificate graph =
  let rules =
    match Analysis.Function_graph.runtime_relation_rules graph "relation_renamed" with
    | Some rules -> rules
    | None -> failwith "renamed relation has no runtime rules"
  in
  let rule =
    match
      List.find_opt
        (fun rule -> rule.Analysis.Function_graph.rule_id = Some "transitive")
        rules
    with
    | Some rule -> rule
    | None -> failwith "renamed relation has no transitive rule"
  in
  let source =
    { Runtime_witness_proof.identity = rule.identity
    ; relation_id = rule.relation_id
    ; rule_id = rule.rule_id; origin = rule.origin; source_echo = rule.source_echo
    ; head = rule.head; prems = rule.prems }
  in
  match Runtime_witness_proof.transitive_domain source with
  | Some domain -> domain
  | None -> failwith "renamed transitive rule has no witness domain"

let test_indexed_constructor_successor_certificate () =
  let sequence_typ = IterT (nat_typ, List) $ region in
  let graph, _ = indexed_constructor_graph sequence_typ in
  match Runtime_truth_successor_domain.certify graph (successor_certificate graph) with
  | Materialized { producers = [ Indexed_constructor producer ]; _ }
    when producer.index_source_id = "index" && producer.prefix = [] -> ()
  | Materialized _ ->
    failwith "indexed-constructor successor did not retain its typed producer shape"
  | Blocked blockers ->
    failwith
      ("finite indexed-constructor successor was blocked: "
       ^ String.concat "; "
           (List.map
              (fun (blocker : Runtime_truth_successor_domain.blocker) -> blocker.reason)
              blockers))

let test_successor_certificate_exact_rule () =
  let sequence_typ = IterT (nat_typ, List) $ region in
  let graph, _ = indexed_constructor_graph sequence_typ in
  let transitive = successor_certificate graph in
  match Runtime_truth_successor_domain.certify graph transitive with
  | Blocked _ -> failwith "exact-rule certificate fixture was blocked"
  | Materialized certificate ->
    if not (Runtime_truth_successor_domain.matches certificate transitive) then
      failwith "materialized successor certificate did not match its source RuleD";
    let other_rule =
      { transitive.Runtime_witness_proof.rule with
        identity =
          source_rule_identity "relation_renamed" ~source_rule_index:2
      ; rule_id = None
      ; origin = origin "indexed-constructor-transitive"
      ; source_echo = transitive.rule.source_echo
      }
    in
    if Runtime_truth_successor_domain.matches certificate { transitive with rule = other_rule } then
      failwith "successor certificate was admitted by relation without the exact RuleD"

let test_anonymous_rule_source_identity () =
  let anonymous =
    RuleD (id "_", [], predicate_mixop, var "x", []) $ region
  in
  let graph = function_graph [ relation_def "anonymous" [ anonymous; anonymous ] ] "anonymous" in
  match Analysis.Function_graph.runtime_relation_rules graph "anonymous" with
  | Some [ left; right ]
    when left.rule_id = None
         && right.rule_id = None
         && left.origin = right.origin
         && left.source_echo = right.source_echo
         && not (Source_rule_identity.equal_rule left.identity right.identity)
         && Source_rule_identity.rule_source_index left.identity = 0
         && Source_rule_identity.rule_source_index right.identity = 1 ->
    ()
  | _ ->
    failwith
      "identical anonymous/no_region RuleD clauses were not distinguished by source index"

let test_anonymous_rule_helper_keys () =
  let anonymous = RuleD (id "_", [], predicate_mixop, var "x", []) $ region in
  let graph =
    function_graph
      [ relation_def "anonymous_keys" [ anonymous; anonymous ] ]
      "anonymous_keys"
  in
  match Analysis.Function_graph.runtime_relation_rules graph "anonymous_keys" with
  | Some [ left; right ] ->
    if Source_rule_identity.rule_key left.identity
       = Source_rule_identity.rule_key right.identity
    then failwith "anonymous RuleD helper keys erased the original source index"
  | _ -> failwith "anonymous helper-key fixture lost its two source RuleD bodies"

let test_indexed_constructor_nonfinite_source () =
  let graph, _ = indexed_constructor_graph nat_typ in
  match Runtime_truth_successor_domain.certify graph (successor_certificate graph) with
  | Blocked blockers
    when List.exists (fun blocker ->
      blocker.Runtime_truth_successor_domain.constructor
      = "RuntimeTruthSuccessorDomain/indexed-constructor/non-finite-source") blockers -> ()
  | Blocked _ -> failwith "non-finite indexed-constructor source had an imprecise blocker"
  | Materialized _ -> failwith "non-finite indexed-constructor source was certified"

let test_indexed_constructor_ordered_enumeration () =
  let request : Runtime_truth_successor_indexed_constructor.request =
    { helper_name = "IndexedConstructor"; origin = origin "indexed-constructor"
    ; index = 1; source_term = Var "SOURCE"; captures = []
    ; index_var = "INDEX"
    ; head_var = "HEAD1:SpectecTerminal"
    ; tail_var = "TAIL1:SpectecTerminals"
    ; successor_term = App ("tag", [ Var "INDEX" ])
    ; successor_guards = [] }
  in
  let result = Runtime_truth_successor_indexed_constructor.materialize request in
  let advances =
    result.statements |> List.exists (fun statement ->
      match statement.node with
      | Ceq (_, App ("_ _", [ App ("tag", [ Var "INDEX" ]);
                              App (_, [ Var "TAIL1:SpectecTerminals";
                                       App ("s_", [ Var "INDEX" ]) ]) ]), _, _) -> true
      | _ -> false)
  in
  if not advances then
    failwith "indexed-constructor enumeration did not preserve source order and advance the position"

let delegated_graph ?(include_definition = true) ?(bound_call = true)
    ?(safe_pattern = true) ?(call_on_left = true)
    ?(guarded_definition = false) ?(partial_definition = false)
    ?(stuck_definition = false) () =
  let sequence_typ = IterT (nat_typ, List) $ region in
  let result_typ = VarT (id "result-shape", []) $ region in
  let context, left, right = var "context", var "left", var "right" in
  let sequence = typed_var sequence_typ "sequence" in
  let element = var "element" in
  let tag = Xl.Atom.Atom "RESULT" $$ region % Xl.Atom.info "regression" in
  let constructor = Xl.Mixop.Seq [ Xl.Mixop.Atom tag; Xl.Mixop.Arg () ] in
  let iterated =
    IterE (element, (List, [ id "element", sequence ]))
    $$ region % sequence_typ
  in
  let pattern =
    if safe_pattern then CaseE (constructor, iterated) $$ region % result_typ
    else sequence
  in
  let call_input = if bound_call then left else var "unbound-input" in
  let call =
    CallE (id "deterministic-source", [ ExpA call_input $ region ])
    $$ region % result_typ
  in
  let binding =
    let left, right = if call_on_left then call, pattern else pattern, call in
    LetPr ([ ExpP (id "sequence", sequence_typ) $ region ], left, right)
    $ region
  in
  let indexed = IdxE (sequence, var "index") $$ region % nat_typ in
  let nested =
    source_rule "nested-indexed"
      (TupE [ context; left; right ] $$ region % nat_typ)
      [ binding; rulepr "parent_relation" [ context; indexed; right ] ]
  in
  let delegated =
    source_rule "delegated"
      (TupE [ context; left; right ] $$ region % nat_typ)
      [ rulepr "child_relation" [ context; left; right ] ]
  in
  let witness = var "witness" in
  let transitive =
    source_rule "transitive"
      (TupE [ context; left; right ] $$ region % nat_typ)
      [ rulepr "domain_relation" [ context; witness ]
      ; rulepr "parent_relation" [ context; left; witness ]
      ; rulepr "parent_relation" [ context; witness; right ]
      ]
  in
  let definition =
    let input = var "input" in
    let rhs =
      if stuck_definition then
        IdxE (ListE [] $$ region % sequence_typ, input) $$ region % result_typ
      else
        input
    in
    let prems =
      if guarded_definition then
        [ IfPr (BoolE true $$ region % (BoolT $ region)) $ region ]
      else []
    in
    let clause =
      DefD ([], [ ExpA input $ region ], rhs, prems)
      $ region
    in
    DecD
      (id "deterministic-source", [ ExpP (id "input", nat_typ) $ region ],
       result_typ, [ clause ])
    $ region
  in
  let defs =
    (if partial_definition then
       let hint =
         { hintid = id "partial"; hintexp = El.Ast.BoolE true $ region }
       in
       [ HintD (DecH (id "deterministic-source", [ hint ]) $ region) $ region ]
     else [])
    @ [ relation_def "parent_relation" [ delegated; transitive ]
    ; relation_def "child_relation" [ nested ]
    ]
  in
  let script =
    runtime_script ((if include_definition then [ definition ] else []) @ defs)
      "parent_relation"
  in
  let index = Analysis.Source_index.of_script script in
  let graph = Analysis.Function_graph.build index in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let source_total ~bound exp =
    Runtime_truth_total_equality.source_total ctx ~bound
      (origin "delegated-call-totality") exp
  in
  let source_zero_or_one ~bound exp =
    Runtime_truth_total_equality.source_zero_or_one ctx ~bound
      (origin "delegated-call-definedness") exp
  in
  graph, source_total, source_zero_or_one

let delegated_certificate graph =
  let rules =
    match Analysis.Function_graph.runtime_relation_rules graph "parent_relation" with
    | Some rules -> rules
    | None -> failwith "delegated parent relation has no runtime rules"
  in
  let rule =
    match
      List.find_opt
        (fun rule -> rule.Analysis.Function_graph.rule_id = Some "transitive")
        rules
    with
    | Some rule -> rule
    | None -> failwith "delegated parent relation has no transitive rule"
  in
  let source =
    { Runtime_witness_proof.identity = rule.identity
    ; relation_id = rule.relation_id
    ; rule_id = rule.rule_id; origin = rule.origin; source_echo = rule.source_echo
    ; head = rule.head; prems = rule.prems }
  in
  match Runtime_witness_proof.transitive_domain source with
  | Some domain -> domain
  | None -> failwith "delegated transitive rule has no witness domain"

let has_successor_blocker constructor = function
  | Runtime_truth_successor_domain.Blocked blockers ->
    List.exists
      (fun blocker ->
        blocker.Runtime_truth_successor_domain.constructor = constructor)
      blockers
  | Materialized _ -> false

let test_delegated_indexed_binding_certificate () =
  let graph, source_total, _ = delegated_graph () in
  match Runtime_truth_successor_domain.certify ~source_total graph (delegated_certificate graph) with
  | Materialized
      { producers =
          [ Delegated
              { producers =
                  [ Indexed
                      { prefix = [ { it = LetPr _; _ } ]
                      ; bindings = [ { premise = { it = LetPr _; _ }; _ } ]
                      ; _ } ]
              ; _ } ]
      ; _ } -> ()
  | Materialized _ ->
    failwith "delegated certificate lost its ordered deterministic binding producer"
  | Blocked blockers ->
    failwith
      ("safe delegated indexed producer was blocked: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_successor_domain.reason)
              blockers))

let test_delegated_binding_orientation () =
  let graph, source_total, _ = delegated_graph ~call_on_left:false () in
  match Runtime_truth_successor_domain.certify ~source_total graph (delegated_certificate graph) with
  | Materialized _ -> ()
  | Blocked _ ->
    failwith "delegated LetPr rejected the symmetric deterministic-call orientation"

let test_delegated_binding_blockers () =
  let check (graph, source_total, _) constructor message =
    let decision =
      Runtime_truth_successor_domain.certify
        ~source_total graph (delegated_certificate graph)
    in
    if not (has_successor_blocker constructor decision) then failwith message
  in
  check (delegated_graph ~bound_call:false ())
    "RuntimeTruthSuccessorDomain/delegated/call-input-unbound"
    "delegated producer accepted an unbound deterministic call input";
  check (delegated_graph ~include_definition:false ())
    "RuntimeTruthSuccessorDomain/delegated/call-not-source-complete-deterministic"
    "delegated producer accepted a call without a source-complete DecD";
  check (delegated_graph ~safe_pattern:false ())
    "RuntimeTruthSuccessorDomain/delegated/result-pattern-unsafe"
    "delegated producer accepted a non-constructor result pattern";
  List.iter
    (fun fixture ->
      check fixture
        "RuntimeTruthSuccessorDomain/delegated/call-not-source-complete-deterministic"
        "delegated producer accepted a call that is not total at this call site")
    [ delegated_graph ~guarded_definition:true ()
    ; delegated_graph ~partial_definition:true ()
    ; delegated_graph ~stuck_definition:true ()
    ]

let test_delegated_zero_or_one_binding () =
  let graph, source_total, source_zero_or_one =
    delegated_graph ~partial_definition:true ~stuck_definition:true ()
  in
  match
    Runtime_truth_successor_domain.certify
      ~source_total ~source_zero_or_one
      graph (delegated_certificate graph)
  with
  | Materialized
      { producers =
          [ Delegated
              { producers =
                  [ Indexed
                      { bindings =
                          [ { domain = Zero_or_one; _ } ]
                      ; _ } ]
              ; _ } ]
      ; _ } -> ()
  | Materialized _ ->
    failwith "zero-or-one DecD binding lost its explicit domain certificate"
  | Blocked blockers ->
    failwith
      ("single-clause partial DecD was not admitted as zero-or-one: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_successor_domain.reason)
              blockers))

let test_runtime_truth_scc_renaming () =
  let x = var "x" in
  let head = TupE [ x; x ] $$ region % nat_typ in
  let alpha =
    source_rule "alpha-cycle" head [ rulepr "beta_renamed" [ x; x ] ]
  in
  let beta =
    source_rule "beta-cycle" head [ rulepr "alpha_renamed" [ x; x ] ]
  in
  let graph =
    function_graph
      [ relation_def "alpha_renamed" [ alpha ]
      ; relation_def "beta_renamed" [ beta ]
      ]
      "alpha_renamed"
  in
  let plan = Runtime_truth_scc.plan graph "alpha_renamed" in
  if not (Runtime_truth_scc.complete plan) then
    failwith "renamed finite relation SCC was blocked by a source-name decision";
  match Runtime_truth_scc.find_scc plan "alpha_renamed" with
  | Some scc when scc.relations = [ "alpha_renamed"; "beta_renamed" ] -> ()
  | Some scc ->
    failwith
      ("renamed mutual recursion did not form one actual SCC: "
       ^ String.concat "," scc.relations
       ^ "; closure=" ^ String.concat "," plan.closure)
  | None -> failwith "renamed runtime relation is absent from its SCC plan"

let test_runtime_truth_open_successor () =
  let x, witness = var "x", var "witness" in
  let head = TupE [ x; x ] $$ region % nat_typ in
  let open_rule =
    source_rule "open-successor" head
      [ rulepr "open_renamed" [ x; witness ] ]
  in
  let graph =
    function_graph [ relation_def "open_renamed" [ open_rule ] ] "open_renamed"
  in
  let plan = Runtime_truth_scc.plan graph "open_renamed" in
  if Runtime_truth_scc.complete plan then
    failwith "open successor generation was accepted as a finite ground SCC";
  if not (List.exists (fun blocker ->
      blocker.Runtime_truth_scc.constructor = "RuntimeTruthScc/RulePr/open-successor")
      plan.blockers)
  then failwith "open successor did not produce its structured blocker"

let test_open_rules_cannot_prove_zero_successors () =
  let certify suffix open_prems =
    let relation_id = "open_zero_" ^ suffix in
    let context, left, right, witness =
      var "context", var "left", var "right", var "witness"
    in
    let open_rule =
      source_rule "_"
        (TupE [ context; left; right ] $$ region % nat_typ)
        (open_prems relation_id context right witness)
    in
    let transitive =
      source_rule "_"
        (TupE [ context; left; right ] $$ region % nat_typ)
        [ rulepr (relation_id ^ "_domain") [ context; witness ]
        ; rulepr relation_id [ context; left; witness ]
        ; rulepr relation_id [ context; witness; right ]
        ]
    in
    let graph = function_graph [ relation_def relation_id [ open_rule; transitive ] ] relation_id in
    let runtime_rules =
      Option.value ~default:[]
        (Analysis.Function_graph.runtime_relation_rules graph relation_id)
    in
    let transitive =
      runtime_rules
      |> List.find_map (fun (rule : Analysis.Function_graph.runtime_search_rule) ->
        let source =
          { Runtime_witness_proof.identity = rule.identity
          ; relation_id = rule.relation_id; rule_id = rule.rule_id
          ; origin = rule.origin; source_echo = rule.source_echo
          ; head = rule.head; prems = rule.prems }
        in
        Runtime_witness_proof.transitive_domain source)
      |> Option.get
    in
    Runtime_truth_successor_domain.certify graph transitive
  in
  (match certify "empty" (fun _ _ _ _ -> []) with
  | Materialized ({ producers = [ Query_endpoint _ ]; _ } as certificate) ->
    if Runtime_truth_successor_domain.decision_complete certificate then
      failwith "prove-only query endpoint acquired exhaustive false coverage"
  | Materialized { producers = []; _ } ->
    failwith "empty open rule was silently accepted as a zero producer"
  | Materialized _ | Blocked _ ->
    failwith "empty query-endpoint rule lost its explicit typed producer");
  (match
     certify "target_conditional" (fun relation_id context right witness ->
       [ rulepr relation_id [ context; witness; right ] ])
   with
  | Blocked blockers
    when List.exists (fun blocker ->
      contains blocker.Runtime_truth_successor_domain.reason
        "no typed proof that the clause produces zero successors") blockers ->
    ()
  | Blocked _ -> failwith "open target-conditional rule produced the wrong blocker"
  | Materialized _ ->
    failwith "target-conditional rule with an unbound witness was admitted")

let rooted_subtyping_certificate ~excluded_bottom =
  let relation_id = "rooted_subtyping" in
  let domain_id = "rooted_domain" in
  let context, left, right, witness =
    var "context", var "left", var "right", var "witness"
  in
  let bottom = NumE (`Nat Z.zero) $$ region % nat_typ in
  let excluded = NumE (`Nat (Z.of_int excluded_bottom)) $$ region % nat_typ in
  let root = NumE (`Nat (Z.of_int 9)) $$ region % nat_typ in
  let sub_rule name head prems =
    RuleD (id name, [], subtyping_mixop, head, prems) $ region
  in
  let rooted =
    sub_rule "rooted"
      (TupE [ context; bottom; right ] $$ region % nat_typ)
      [ rulepr_with subtyping_mixop relation_id [ context; right; root ]
      ; IfPr
          (CmpE (`NeOp, `NatT, right, excluded)
           $$ region % (BoolT $ region))
        $ region
      ]
  in
  let universal =
    sub_rule "bottom"
      (TupE [ context; bottom; right ] $$ region % nat_typ) []
  in
  let transitive =
    sub_rule "transitive"
      (TupE [ context; left; right ] $$ region % nat_typ)
      [ rulepr_with predicate_mixop domain_id [ context; witness ]
      ; rulepr_with subtyping_mixop relation_id [ context; left; witness ]
      ; rulepr_with subtyping_mixop relation_id [ context; witness; right ]
      ]
  in
  let domain_result =
    TupT [ id "context", nat_typ; id "value", nat_typ ] $ region
  in
  let domain_rule =
    RuleD
      (id "domain", [], predicate_mixop,
       TupE [ context; witness ] $$ region % domain_result, [])
    $ region
  in
  let domain =
    RelD
      (id domain_id, [], predicate_mixop, domain_result, [ domain_rule ])
    $ region
  in
  let relation_result =
    TupT
      [ id "context", nat_typ; id "left", nat_typ; id "right", nat_typ ]
    $ region
  in
  let relation =
    RelD
      (id relation_id, [], subtyping_mixop, relation_result,
       [ rooted; universal; transitive ])
    $ region
  in
  let graph = function_graph [ domain; relation ] relation_id in
  let transitive =
    Analysis.Function_graph.runtime_relation_rules graph relation_id
    |> Option.value ~default:[]
    |> List.find_map (fun rule ->
         if rule.Analysis.Function_graph.rule_id <> Some "transitive" then None
         else
           Runtime_witness_proof.transitive_domain
             { Runtime_witness_proof.identity = rule.identity
             ; relation_id = rule.relation_id
             ; rule_id = rule.rule_id
             ; origin = rule.origin
             ; source_echo = rule.source_echo
             ; head = rule.head
             ; prems = rule.prems
             })
    |> Option.get
  in
  Runtime_truth_successor_domain.certify graph transitive

let test_rooted_subtyping_cut_certificate () =
  (match rooted_subtyping_certificate ~excluded_bottom:0 with
  | Materialized certificate
    when Runtime_truth_successor_domain.decision_complete certificate -> ()
  | Materialized _ ->
    failwith "rooted subtyping schema did not acquire complete successor coverage"
  | Blocked _ -> failwith "rooted subtyping schema was not materialized");
  match rooted_subtyping_certificate ~excluded_bottom:1 with
  | Materialized certificate
    when not (Runtime_truth_successor_domain.decision_complete certificate) -> ()
  | Materialized _ ->
    failwith "rooted subtyping schema accepted a guard excluding another bottom"
  | Blocked _ ->
    failwith "mutated rooted subtyping schema lost its conservative materialization"

let planned_rule plan relation_id =
  plan.Runtime_truth_scc.sccs
  |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
  |> List.find (fun rule ->
       rule.Runtime_truth_scc.source.relation_id = relation_id)

let test_runtime_truth_iter_local_scope () =
  let list_typ = IterT (nat_typ, List) $ region in
  let source = typed_var list_typ "renamed_source" in
  let local = var "renamed_local" in
  let body = rulepr "renamed_iter_leaf" [ local; local ] in
  let iter = IterPr (body, (List, [ id "renamed_local", source ])) $ region in
  let leaf =
    source_rule "renamed-leaf"
      (TupE [ var "leaf_value"; var "leaf_value" ] $$ region % nat_typ) []
  in
  let root name head prems = relation_def name [ source_rule name head prems ] in
  let good =
    root "renamed_iter_good"
      (TupE [ source; source ] $$ region % nat_typ) [ iter ]
  in
  let graph = function_graph [ relation_def "renamed_iter_leaf" [ leaf ]; good ]
      "renamed_iter_good"
  in
  let plan = Runtime_truth_scc.plan graph "renamed_iter_good" in
  if not (Runtime_truth_scc.complete plan) then
    failwith "IterPr generator binder was not local-bound in its body";
  (match (planned_rule plan "renamed_iter_good").premises with
  | [ Finite_iter { body = [ Finite_rule_call _ ]; _ } ] -> ()
  | _ -> failwith "IterPr body lost its finite local-binder call plan");
  let unbound =
    root "renamed_iter_unbound"
      (TupE [ var "outer"; var "outer" ] $$ region % nat_typ) [ iter ]
  in
  let unbound_plan =
    Runtime_truth_scc.plan
      (function_graph [ relation_def "renamed_iter_leaf" [ leaf ]; unbound ]
         "renamed_iter_unbound")
      "renamed_iter_unbound"
  in
  if not (List.exists (fun blocker ->
      blocker.Runtime_truth_scc.constructor
      = "RuntimeTruthScc/IterPr/generator-domain-unbound") unbound_plan.blockers)
  then failwith "IterPr source list was not required to be outer-bound";
  let escaping =
    root "renamed_iter_escape"
      (TupE [ source; source ] $$ region % nat_typ)
      [ iter; rulepr "renamed_iter_leaf" [ local; local ] ]
  in
  let escape_plan =
    Runtime_truth_scc.plan
      (function_graph [ relation_def "renamed_iter_leaf" [ leaf ]; escaping ]
         "renamed_iter_escape")
      "renamed_iter_escape"
  in
  if not (List.exists (fun blocker ->
      blocker.Runtime_truth_scc.constructor
      = "RuntimeTruthScc/RulePr/open-successor") escape_plan.blockers)
  then failwith "IterPr-local generator binder escaped into a later premise"

let test_runtime_truth_dependency_schedule () =
  let list_typ = IterT (nat_typ, List) $ region in
  let rectype_typ = VarT (id "renamed_bundle", []) $ region in
  let rectype = typed_var rectype_typ "renamed_bundle_value" in
  let count = var "renamed_arity" in
  let member = var "renamed_member" in
  let members = typed_var list_typ "renamed_members" in
  let tag = Xl.Atom.Atom "RENAMED" $$ region % Xl.Atom.info "regression" in
  let constructor = Xl.Mixop.Seq [ Xl.Mixop.Atom tag; Xl.Mixop.Arg () ] in
  let sequence_pattern =
    IterE
      (member, (ListN (count, None), [ id "renamed_member", members ]))
    $$ region % list_typ
  in
  let pattern = CaseE (constructor, sequence_pattern) $$ region % rectype_typ in
  let equality value pattern =
    IfPr (CmpE (`EqOp, `NatT, pattern, value) $$ region % (BoolT $ region))
    $ region
  in
  let dependency = rulepr "renamed_schedule_leaf" [ count; members ] in
  let head = TupE [ rectype; rectype ] $$ region % nat_typ in
  let leaf =
    source_rule "renamed-schedule-leaf"
      (TupE [ var "leaf_count"; typed_var list_typ "leaf_members" ]
       $$ region % nat_typ) []
  in
  let good_rule =
    source_rule "renamed-schedule-good" head
      [ dependency; equality rectype pattern ]
  in
  let partial_name = "renamed_partial_unfolder" in
  let partial =
    CallE (id partial_name, [ ExpA rectype $ region ]) $$ region % rectype_typ
  in
  let noninvertible =
    CaseE
      ( constructor
      , BinE (`AddOp, `NatT, member,
          NumE (`Nat Z.one) $$ region % nat_typ) $$ region % nat_typ )
    $$ region % rectype_typ
  in
  let bad_rule =
    source_rule "renamed-schedule-bad" head
      [ dependency; equality partial noninvertible ]
  in
  let declaration =
    DecD
      ( id partial_name
      , [ ExpP (id "renamed_bundle_value", rectype_typ) $ region ]
      , rectype_typ
      , [] )
    $ region
  in
  let script =
    [ declaration
    ; relation_def "renamed_schedule_leaf" [ leaf ]
    ; relation_def "renamed_schedule_good" [ good_rule ]
    ; relation_def "renamed_schedule_bad" [ bad_rule ]
    ]
  in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let total_value ~bound exp =
    Runtime_truth_total_equality.source_total
      ctx ~bound (origin "renamed-dependency-schedule") exp
  in
  let graph = Context.function_graph ctx in
  let good = Runtime_truth_scc.plan ~total_value graph "renamed_schedule_good" in
  if not (Runtime_truth_scc.complete good) then
    failwith "later total invertible equality did not close an earlier dependency";
  let rule = planned_rule good "renamed_schedule_good" in
  (match rule.premises with
  | [ Finite_rule_call { relation_id; _ }; Source_boolean _ ]
    when relation_id = "renamed_schedule_leaf" -> ()
  | _ -> failwith "runtime truth rule did not preserve source premise order");
  (match Runtime_truth_scc.scheduled_premises rule, rule.schedule with
  | [ (1, Source_boolean _); (0, Finite_rule_call { relation_id; _ }) ], [ 1; 0 ]
    when relation_id = "renamed_schedule_leaf" -> ()
  | _ -> failwith "dependency schedule did not reorder only execution");
  let bad = Runtime_truth_scc.plan ~total_value graph "renamed_schedule_bad" in
  if Runtime_truth_scc.complete bad then
    failwith "partial non-invertible equality was used as a dependency binding";
  if not (List.exists (fun blocker ->
      blocker.Runtime_truth_scc.constructor
      = "RuntimeTruthScc/RulePr/open-successor") bad.blockers)
  then failwith "partial dependency schedule lost its structured blocker"

let test_runtime_validation_certificate_is_closed_and_use_exact () =
  let certified source_params premise_args runtime_demanded =
    Runtime_validation_certificate.certified
      ~predicate_marker:true
      ~source_params
      ~runtime_demanded
      ~mixop_equal:Il.Eq.eq_mixop
      ~declaration_mixop:predicate_mixop
      ~premise_args
      ~premise_mixop:predicate_mixop
      ~result:nat_typ
      ~premise_exp:(NumE (`Nat Z.zero) $$ region % nat_typ)
  in
  if not (certified [] [] false) then
    failwith "closed non-runtime validation use lost its certificate";
  if certified [ ExpP (id "parameter", nat_typ) $ region ] [] false then
    failwith "open relation parameters acquired a validation certificate";
  if certified []
       [ ExpA (NumE (`Nat Z.zero) $$ region % nat_typ) $ region ] false then
    failwith "caller-supplied RulePr arguments acquired a validation certificate";
  if certified [] [] true then
    failwith "an exact runtime-demanded RulePr use was discharged as validation-only";
  match
    Runtime_validation_certificate.premise_shape
      ~predicate_marker:true
      ~source_params:[]
      ~mixop_equal:Il.Eq.eq_mixop
      ~declaration_mixop:predicate_mixop
      ~premise_args:[]
      ~premise_mixop:predicate_mixop
      ~result:nat_typ
      ~premise_exp:(NumE (`Nat Z.zero) $$ region % nat_typ)
  with
  | Certified -> ()
  | Unavailable _ ->
    failwith "runtime-computed validation guard lost its declaration/use shape certificate"

let test_runtime_truth_worklist_key () =
  let graph = function_graph [ relation_def "ground_relation" [] ] "ground_relation" in
  let plan = Runtime_truth_scc.plan graph "ground_relation" in
  let request phase terms sorts =
    { Runtime_truth_worklist_helper.relation_id = "ground_relation"
    ; specialization = "ground"
    ; input_terms = terms
    ; input_sorts = sorts
    ; phase
    ; mode = Runtime_truth_worklist_helper.Prove
    ; plan
    }
  in
  let base = request Runtime_truth_scc.Goal [ Const "a" ] [ sort "SpectecTerminal" ] in
  let term = request Goal [ Const "b" ] [ sort "SpectecTerminal" ] in
  let sort_key = request Goal [ Const "a" ] [ sort "SpectecTerminals" ] in
  let phase = request List_indexed [ Const "a" ] [ sort "SpectecTerminal" ] in
  let decide = { base with Runtime_truth_worklist_helper.mode = Decide } in
  let joined = request Goal [ Var "a,const:b" ] [ sort "SpectecTerminal" ] in
  let split =
    request Goal [ Var "a"; Const "b" ]
      [ sort "SpectecTerminal"; sort "SpectecTerminal" ]
  in
  let closure_left = { base with plan = { plan with closure = [ "a,b"; "c" ] } } in
  let closure_right = { base with plan = { plan with closure = [ "a"; "b,c" ] } } in
  let key = Runtime_truth_worklist_helper.key base in
  if key = Runtime_truth_worklist_helper.key term then
    failwith "worklist key erased a complete input term";
  if key = Runtime_truth_worklist_helper.key sort_key then
    failwith "worklist key erased a complete input sort";
  if key = Runtime_truth_worklist_helper.key phase then
    failwith "worklist key erased the indexed/list phase";
  if key = Runtime_truth_worklist_helper.key decide then
    failwith "worklist key merged positive and total proof modes";
  if Runtime_truth_worklist_helper.key joined
     = Runtime_truth_worklist_helper.key split
  then failwith "worklist key has a comma/constructor boundary collision";
  if Runtime_truth_worklist_helper.key closure_left
     = Runtime_truth_worklist_helper.key closure_right
  then failwith "worklist key has a closure-list boundary collision"

let test_worklist_enabledness_requires_equation_first_failures () =
  let graph = function_graph [ relation_def "enabledness_leaf" [] ] "enabledness_leaf" in
  let plan = Runtime_truth_scc.plan graph "enabledness_leaf" in
  let positive_request =
    { Runtime_truth_worklist_helper.relation_id = "enabledness_leaf"
    ; specialization = "ground"
    ; input_terms = []
    ; input_sorts = []
    ; phase = Runtime_truth_scc.Goal
    ; mode = Runtime_truth_worklist_helper.Prove
    ; plan
    }
  in
  let total_request =
    { positive_request with Runtime_truth_worklist_helper.mode = Decide }
  in
  let decision =
    { Runtime_truth_worklist_enabledness.positive_helper_name = "EnabledPositive"
    ; positive_request
    ; total_helper_name = "EnabledTotal"
    ; total_request
    }
  in
  let request =
    { Runtime_enabledness_helper.relation_id = "enabledness_leaf"
    ; rule_id = None
    ; call_terms = []
    ; predecessor_terms = []
    ; input_sorts = []
    ; lhs_conditions = []
    ; premise_eq_conditions = [ BoolCond (Const "true") ]
    ; premise_rule_conditions =
        [ Runtime_truth_worklist_enabledness.positive_condition decision ]
    ; runtime_search_requests = []
    ; runtime_truth_search_requests = []
    ; runtime_truth_decisions = []
    ; runtime_truth_worklist_decisions = [ decision ]
    ; source_echo = Some "ordered equation then runtime worklist"
    }
  in
  let script = runtime_script [ relation_def "enabledness_leaf" [] ] "enabledness_leaf" in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let materialized =
    Runtime_enabledness_materializer.materialize ctx
      [ { name = "EnablednessFirstFailure"
        ; origin = origin "enabledness-first-failure"
        ; request
        } ]
  in
  if materialized.statements <> [] then
    failwith "worklist enabledness omitted equation first-failure branches";
  if not (List.exists (fun diagnostic ->
      diagnostic.Diagnostics.constructor
      = "RuntimeEnabledness/materializer/false-unimplemented"
      && Diagnostics.is_fatal diagnostic) materialized.diagnostics)
  then failwith "worklist enabledness lost its explicit first-failure blocker"

let test_legacy_truth_enabledness_rejects_equations () =
  let truth_request =
    { Runtime_truth_search_helper.rel_id = "legacy_enabledness_leaf"
    ; input_terms = []
    ; input_sorts = []
    ; recursion = Acyclic
    ; closure = [ "legacy_enabledness_leaf" ]
    ; rules = []
    }
  in
  let truth_decision_request =
    { Runtime_truth_decision_helper.truth_helper_name = "LegacyTruth"
    ; truth_request
    }
  in
  let truth_decision =
    { Runtime_enabledness_helper.helper_name = "LegacyDecision"
    ; request = truth_decision_request
    }
  in
  let request =
    { Runtime_enabledness_helper.relation_id = "legacy_enabledness_leaf"
    ; rule_id = None
    ; call_terms = []
    ; predecessor_terms = []
    ; input_sorts = []
    ; lhs_conditions = []
    ; premise_eq_conditions = [ BoolCond (Const "legacyEquation") ]
    ; premise_rule_conditions =
        [ Runtime_truth_search_helper.rewrite_condition
            ~helper_name:"LegacyTruth" truth_request ]
    ; runtime_search_requests = []
    ; runtime_truth_search_requests = []
    ; runtime_truth_decisions = [ truth_decision ]
    ; runtime_truth_worklist_decisions = []
    ; source_echo = Some "legacy equation before runtime truth"
    }
  in
  let script =
    runtime_script
      [ relation_def "legacy_enabledness_leaf" [] ]
      "legacy_enabledness_leaf"
  in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let result =
    Runtime_enabledness_materializer.materialize ctx
      [ { name = "LegacyEnablednessEquation"
        ; origin = origin "legacy-enabledness-equation"
        ; request
        } ]
  in
  if result.statements <> [] then
    failwith "legacy runtime-truth enabledness emitted reordered equations";
  if not
       (List.exists
          (fun diagnostic ->
            Diagnostics.is_fatal diagnostic
            && diagnostic.Diagnostics.constructor
               = "RuntimeEnabledness/materializer/legacy-truth-equation-order")
          result.diagnostics)
  then
    failwith "legacy runtime-truth enabledness lost its equation-order blocker"

let test_transitive_support_materialization () =
  let identity =
    { Runtime_truth_worklist_indexed.phase =
        Runtime_truth_worklist_indexed.Transitive
    ; rule_index = 1
    ; premise_index = None
    }
  in
  let witness = Var "HEAD2:SpectecTerminal" in
  let request : Runtime_truth_transitive_materializer.request =
    { helper_name = "TransitiveSupport"
    ; origin = origin "transitive-support"
    ; identity
    ; mode = Runtime_truth_worklist_indexed.Decide
    ; candidates = App ("_ _", [ Var "A"; App ("_ _", [ Var "A"; Var "B" ]) ])
    ; captures = []
    ; support_head_var = "HEAD1:SpectecTerminal"
    ; support_tail_var = "TAIL1:SpectecTerminals"
    ; indexed_head_var = "HEAD2:SpectecTerminal"
    ; indexed_tail_var = "TAIL2:SpectecTerminals"
    ; domain_true = [ EqCondition (BoolCond (App ("domain", [ witness ]))) ]
    ; domain_false = []
    ; left_true = RewriteCond (App ("left", [ witness ]), Const "proved")
    ; right_true = RewriteCond (App ("right", [ witness ]), Const "proved")
    ; left_false = RewriteCond (App ("left", [ witness ]), Const "refuted")
    ; right_false = RewriteCond (App ("right", [ witness ]), Const "refuted")
    ; result_sort = sort "Truth"
    ; proved = Const "proved"
    ; refuted = Const "refuted"
    }
  in
  let result = Runtime_truth_transitive_materializer.materialize request in
  let deduplicates =
    List.exists (fun statement ->
      match statement.Maude_ir.node with
      | Ceq (App (op, [ App ("_ _", [ head; tail ]) ]), App (op', [ tail' ]),
             [ BoolCond (App ("contains", [ head'; tail'' ])) ], _)
        when op = op' && head = head' && tail = tail' && tail = tail'' -> true
      | _ -> false)
      result.statements
  in
  let domain_before_children =
    List.exists (fun statement ->
      match statement.Maude_ir.node with
      | Crl (_, _, _, EqCondition (BoolCond (App ("domain", _)))
                       :: RewriteCond (App ("left", _), _)
                       :: RewriteCond (App ("right", _), _) :: _) -> true
      | _ -> false)
      result.statements
  in
  let first_failure_prefixes =
    let has prefix =
      List.exists (fun statement ->
        match statement.Maude_ir.node with
        | Crl (_, _, _, actual) ->
          let rec starts_with prefix actual =
            match prefix, actual with
            | [], _ -> true
            | expected :: prefix, condition :: actual
              when expected = condition -> starts_with prefix actual
            | _ -> false
          in
          starts_with prefix actual
        | _ -> false)
        result.statements
    in
    has (request.domain_true @ [ request.left_false ])
    && has
         (request.domain_true
          @ [ request.left_true; request.right_false ])
  in
  if not deduplicates then
    failwith "transitive support did not structurally deduplicate certified producers";
  if not domain_before_children then
    failwith "transitive AND edge did not preserve the domain child before recursion";
  if not first_failure_prefixes then
    failwith "transitive false alternatives lost their ordered first-failure prefixes"

let test_renamed_synthetic_cyclic_false () =
  let x = var "x" in
  let head = TupE [ x; x ] $$ region % nat_typ in
  let alpha = source_rule "alpha-cycle" head [ rulepr "beta_renamed" [ x; x ] ] in
  let beta = source_rule "beta-cycle" head [ rulepr "alpha_renamed" [ x; x ] ] in
  let script =
    runtime_script
      [ relation_def "alpha_renamed" [ alpha ]
      ; relation_def "beta_renamed" [ beta ]
      ]
      "alpha_renamed"
  in
  let index = Analysis.Source_index.of_script script in
  let builtins = Builtin_registry.of_source_index index in
  let ctx = Context.create index builtins in
  let plan = Runtime_truth_scc.plan (Context.function_graph ctx) "alpha_renamed" in
  let request =
    { Runtime_truth_worklist_helper.relation_id = "alpha_renamed"
    ; specialization = "nat,nat"
    ; input_terms = [ Const "0"; Const "0" ]
    ; input_sorts = [ sort "Nat"; sort "Nat" ]
    ; phase = Goal
    ; mode = Runtime_truth_worklist_helper.Decide
    ; plan
    }
  in
  let result =
    Runtime_truth_worklist_materializer.materialize ctx
      [ { name = "RenamedScc"; origin = origin "renamed-scc"; request } ]
  in
  let statements =
    match result with
    | Runtime_truth_worklist_materializer.Blocked_result diagnostics ->
      failwith
        ("closed renamed SCC did not materialize both proof modes: "
         ^ String.concat "; "
             (List.map (fun diagnostic -> diagnostic.Diagnostics.reason) diagnostics))
    | Complete_result complete ->
      Runtime_truth_worklist_materializer.complete_statements complete
  in
  let labels =
    statements |> List.filter_map (fun statement ->
      match statement.node with
      | Rl (label, _, _) | Crl (label, _, _, _) -> label
      | _ -> None)
  in
  if not (List.exists (fun label -> contains label "unfounded-certificate") labels) then
    failwith "mutual cycle lacks a finite unfounded-set certificate";
  if not (List.exists (fun label -> contains label "-proved") labels) then
    failwith "worklist lacks its least-fixed-point proved result";
  if not (List.exists (fun label -> contains label "-refuted") labels) then
    failwith "worklist lacks its separate refuted result"

let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ

let materialize_renamed_ground name rules input_terms =
  let script = runtime_script [ relation_def name rules ] name in
  let index = Analysis.Source_index.of_script script in
  let builtins = Builtin_registry.of_source_index index in
  let ctx = Context.create index builtins in
  let request =
    { Runtime_truth_worklist_helper.relation_id = name
    ; specialization = "nat,nat"
    ; input_terms
    ; input_sorts = [ sort "Nat"; sort "Nat" ]
    ; phase = Goal
    ; mode = Decide
    ; plan = Runtime_truth_scc.plan (Context.function_graph ctx) name
    }
  in
  Runtime_truth_worklist_materializer.materialize ctx
    [ { name = "RenamedGround"; origin = origin "renamed-ground"; request } ]

let labels result =
  match result with
  | Runtime_truth_worklist_materializer.Blocked_result diagnostics ->
    failwith
      ("expected complete worklist: "
       ^ String.concat "; "
           (List.map (fun diagnostic -> diagnostic.Diagnostics.reason) diagnostics))
  | Complete_result complete ->
    Runtime_truth_worklist_materializer.complete_statements complete
    |> List.filter_map (fun statement ->
      match statement.node with
      | Rl (label, _, _) | Crl (label, _, _, _) -> label
      | _ -> None)

let test_renamed_synthetic_positive () =
  let fact =
    source_rule "renamed-fact"
      (TupE [ nat 0; nat 0 ] $$ region % nat_typ) []
  in
  let result = materialize_renamed_ground "gamma_renamed" [ fact ] [ Const "0"; Const "0" ] in
  if not (List.exists (fun label -> contains label "-proved") (labels result)) then
    failwith "renamed positive query lacks a finite proof rule"

let test_renamed_synthetic_negative () =
  let fact =
    source_rule "renamed-only-fact"
      (TupE [ nat 0; nat 0 ] $$ region % nat_typ) []
  in
  let result = materialize_renamed_ground "delta_renamed" [ fact ] [ Const "0"; Const "1" ] in
  let labels = labels result in
  if not (List.exists (fun label -> contains label "rule-mismatch") labels) then
    failwith "renamed negative query lacks source-head mismatch refutation";
  if not (List.exists (fun label -> contains label "-refuted") labels) then
    failwith "renamed negative query lacks a total false result"

let constructor_entry case_origin constructor_op status =
  { Constructor_registry.source_category = "family"
  ; declaring_category = "family"
  ; static_args_key = None
  ; mixop
  ; arity = 0
  ; constructor_op
  ; projection_ops = []
  ; payload_labels = []
  ; payload_witnesses = []
  ; payload_sorts = []
  ; origin = case_origin
  ; enclosing = []
  ; status
  ; construction_domain = Constructor_registry.Total_constructor
  }

let test_direct_successors_cover_transitive_decision () =
  let context, left, right, witness =
    var "partial_context", var "partial_left", var "partial_right",
    var "partial_witness"
  in
  let witness_typ = VarT (id "family", []) $ region in
  let closed_witness =
    CaseE (mixop, TupE [] $$ region % nat_typ) $$ region % witness_typ
  in
  let domain_id = "partial_positive_domain" in
  let relation_id = "partial_positive_relation" in
  let domain_rules =
    [ source_rule "closed"
        (TupE [ context; closed_witness ] $$ region % nat_typ) []
    ; source_rule "open"
        (TupE [ context; witness ] $$ region % nat_typ)
        [ IfPr (BoolE true $$ region % (BoolT $ region)) $ region ]
    ]
  in
  let base =
    source_rule "base"
      (TupE [ context; left; left ] $$ region % nat_typ) []
  in
  let transitive =
    source_rule "transitive"
      (TupE [ context; left; right ] $$ region % nat_typ)
      [ rulepr domain_id [ context; witness ]
      ; rulepr relation_id [ context; left; witness ]
      ; rulepr relation_id [ context; witness; right ]
      ]
  in
  let graph =
    function_graph
      [ relation_def domain_id domain_rules
      ; relation_def relation_id [ base; transitive ]
      ]
      relation_id
  in
  let constructors = Constructor_registry.create () in
  Constructor_registry.register constructors
    (constructor_entry (origin "partial-domain-constructor")
       "partialDomainCtor" Constructor_registry.Emitted);
  let transitive =
    Analysis.Function_graph.runtime_relation_rules graph relation_id
    |> Option.get
    |> List.find_map (fun (rule : Analysis.Function_graph.runtime_search_rule) ->
      let source =
        { Runtime_witness_proof.identity = rule.identity
        ; relation_id = rule.relation_id
        ; rule_id = rule.rule_id
        ; origin = rule.origin
        ; source_echo = rule.source_echo
        ; head = rule.head
        ; prems = rule.prems
        }
      in
      Runtime_witness_proof.transitive_domain source)
    |> Option.get
  in
  match Runtime_truth_successor_domain.certify ~constructors graph transitive with
  | Blocked blockers ->
    failwith
      ("proven positive domain candidate was discarded: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_successor_domain.reason)
              blockers))
  | Materialized certificate ->
    if certificate.domain_candidates = [] then
      failwith "positive domain proof retained no certified candidate";
    if not (Runtime_truth_successor_domain.decision_complete certificate) then
      failwith "complete direct-successor rules did not certify transitive decision"

let unary_case_entry
    category constructor_op projection_op payload_sort construction_domain =
  { Constructor_registry.source_category = Naming.source_owner category
  ; declaring_category = Naming.source_owner category
  ; static_args_key = None
  ; mixop
  ; arity = 1
  ; constructor_op
  ; projection_ops = [ projection_op ]
  ; payload_labels = [ Constructor_registry.Structural_payload ]
  ; payload_witnesses = [ Const "renamed-payload-witness" ]
  ; payload_sorts = [ payload_sort ]
  ; origin = origin (category ^ "-case")
  ; enclosing = []
  ; status = Constructor_registry.Emitted
  ; construction_domain
  }

let test_exact_case_constructor_domains () =
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let inner_category = "renamed_index_shape" in
  let outer_category = "renamed_reference_shape" in
  Constructor_registry.register
    (Context.constructors ctx)
    (unary_case_entry
       inner_category "inner.wrap_" "inner.project_" (sort "Nat")
       Constructor_registry.Certified_representation_constructor);
  Constructor_registry.register
    (Context.constructors ctx)
    (unary_case_entry
       outer_category "outer.wrap_" "outer.project_"
       (sort "SpectecTerminal") Constructor_registry.Total_constructor);
  let inner_typ = VarT (id inner_category, []) $ region in
  let outer_typ = VarT (id outer_category, []) $ region in
  let payload = var "renamed_payload" in
  let inner = CaseE (mixop, payload) $$ region % inner_typ in
  let nested = CaseE (mixop, inner) $$ region % outer_typ in
  let env =
    Expr_env.add Expr_env.empty "renamed_payload"
      { term = Var "PAYLOAD"; sort = sort "Nat"; typ = nat_typ }
  in
  (match
     Runtime_truth_total_equality.source_equality_alternatives
       ~bound_vars:[ "PAYLOAD" ] ctx env (origin "nested-total-case") nested nested
   with
  | Ok (_, _, _, _ :: _, diagnostics)
    when not (List.exists Diagnostics.is_fatal diagnostics) -> ()
  | Ok _ -> failwith "nested exact constructor lost its false equality branch"
  | Error blockers ->
    failwith
      ("nested exact constructor was not certified from registry identity: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_total_equality.reason)
              blockers)));
  let guarded_category = "renamed_guarded_shape" in
  let guarded_ctx = Context.create index (Builtin_registry.of_source_index index) in
  Constructor_registry.register
    (Context.constructors guarded_ctx)
    (unary_case_entry
       guarded_category "guarded.wrap_" "guarded.project_" (sort "Nat")
       (Constructor_registry.Guarded_constructor
          "source typcase retains one unresolved premise"));
  let guarded_typ = VarT (id guarded_category, []) $ region in
  let guarded = CaseE (mixop, payload) $$ region % guarded_typ in
  match
    Runtime_truth_total_equality.source_equality_alternatives
      ~bound_vars:[ "PAYLOAD" ] guarded_ctx env
      (origin "guarded-case") guarded guarded
  with
  | Error blockers
    when List.exists
           (fun blocker ->
             blocker.Runtime_truth_total_equality.constructor
             = "RuntimeTruthTotalEquality/CaseE/constructor-domain")
           blockers -> ()
  | Error _ -> failwith "guarded constructor lost its exact domain blocker"
  | Ok _ -> failwith "guarded constructor was certified total from its payload alone"

let length_guarded_entry category =
  { Constructor_registry.source_category = Naming.source_owner category
  ; declaring_category = Naming.source_owner category
  ; static_args_key = None
  ; mixop
  ; arity = 1
  ; constructor_op = "length.guard.wrap_"
  ; projection_ops = [ "length.guard.project_" ]
  ; payload_labels = [ Constructor_registry.Structural_payload ]
  ; payload_witnesses = [ Const "renamed-sequence-witness" ]
  ; payload_sorts = [ sort "SpectecTerminals" ]
  ; origin = origin (category ^ "-length-guard")
  ; enclosing = []
  ; status = Constructor_registry.Emitted
  ; construction_domain =
      Constructor_registry.Length_guarded_representation_constructor
        { payload_index = 0
        ; closed_bound = nat 4_294_967_296
        ; guard_origin = origin (category ^ "-length-bound")
        }
  }

let length_guarded_map_result name make_payload =
  let category = "renamed_length_guard_" ^ name in
  let guarded_typ = VarT (id category, []) $ region in
  let sequence_typ = IterT (nat_typ, List) $ region in
  let sequence name = VarE (id name) $$ region % sequence_typ in
  let input_pattern =
    CaseE (mixop, sequence "source_items") $$ region % guarded_typ
  in
  let payload = make_payload sequence_typ (sequence "source_items") in
  let result = CaseE (mixop, payload) $$ region % guarded_typ in
  let declaration =
    DecD
      (id name,
       [ ExpP (id "guarded_input", guarded_typ) $ region ],
       guarded_typ,
       [ DefD ([], [ ExpA input_pattern $ region ], result, []) $ region ])
    $ region
  in
  let index = Analysis.Source_index.of_script [ declaration ] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let entry = length_guarded_entry category in
  Constructor_registry.note_source_case
    (Context.constructors ctx)
    ~source_category:entry.source_category
    ~static_args_key:entry.static_args_key
    entry.origin;
  Constructor_registry.register (Context.constructors ctx) entry;
  let input = VarE (id "guarded_input") $$ region % guarded_typ in
  let call = CallE (id name, [ ExpA input $ region ]) $$ region % guarded_typ in
  let env =
    Expr_env.add Expr_env.empty "guarded_input"
      { term = Var "GUARDED-INPUT"
      ; sort = sort "SpectecTerminal"
      ; typ = guarded_typ
      }
  in
  Runtime_truth_total_equality.false_conditions
    ~bound_vars:[ "GUARDED-INPUT" ] ctx env (origin name) `EqOp call call

let list_map_payload sequence_typ source =
  let generator = id "mapped_item" in
  let body = VarE generator $$ region % nat_typ in
  IterE (body, (List, [ generator, source ])) $$ region % sequence_typ

let test_length_guarded_case_map_totality () =
  match length_guarded_map_result "renamed_length_map" list_map_payload with
  | Ok (_, diagnostics) when not (List.exists Diagnostics.is_fatal diagnostics) -> ()
  | Ok _ -> failwith "length-preserving CaseE map retained fatal diagnostics"
  | Error blockers ->
    failwith
      ("single-generator List map lost its source length certificate: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_total_equality.reason)
              blockers))

let expect_length_guard_block name make_payload =
  match length_guarded_map_result name make_payload with
  | Error blockers
    when List.exists
           (fun blocker ->
             blocker.Runtime_truth_total_equality.constructor
             = "RuntimeTruthTotalEquality/CaseE/constructor-domain")
           blockers -> ()
  | Error _ -> failwith (name ^ " lost its exact CaseE domain blocker")
  | Ok _ -> failwith (name ^ " acquired a length-preservation certificate")

let test_ambiguous_case_map_cardinality_blocked () =
  expect_length_guard_block "renamed_length_listn"
    (fun sequence_typ source ->
      let generator = id "counted_item" in
      let body = VarE generator $$ region % nat_typ in
      IterE (body, (ListN (nat 1, None), [ generator, source ]))
      $$ region % sequence_typ);
  expect_length_guard_block "renamed_length_zip"
    (fun sequence_typ source ->
      let left = id "left_item" in
      let right = id "right_item" in
      let body = VarE left $$ region % nat_typ in
      IterE (body, (List, [ left, source; right, source ]))
      $$ region % sequence_typ);
  expect_length_guard_block "renamed_length_optional"
    (fun sequence_typ _source ->
      let optional_typ = IterT (nat_typ, Opt) $ region in
      let optional_source = VarE (id "optional_items") $$ region % optional_typ in
      let generator = id "optional_item" in
      let body = VarE generator $$ region % nat_typ in
      let optional =
        IterE (body, (Opt, [ generator, optional_source ]))
        $$ region % optional_typ
      in
      LiftE optional $$ region % sequence_typ)

let test_utf8_representation_certificate () =
  let backend = Builtin_backend.load () in
  let expect key category constructor witness =
    match Builtin_backend.representation backend key with
    | None -> failwith ("missing backend representation contract " ^ key)
    | Some representation ->
      if Builtin_backend.representation_category representation <> category
         || Builtin_backend.representation_constructor representation <> constructor
         || Builtin_backend.representation_witness representation <> witness
      then failwith ("malformed backend representation contract " ^ key)
  in
  expect "unsigned" "uN" "uN.wrap" None;
  expect "utf8-char" "char" "char.wrap" (Some "syn.char");
  expect "utf8-byte" "byte" "byte.wrap" None

let test_constructor_family_completeness () =
  let registry = Constructor_registry.create () in
  let left, right = origin "family-left", origin "family-right" in
  Constructor_registry.note_source_case registry ~source_category:"family" ~static_args_key:None left;
  Constructor_registry.note_source_case registry ~source_category:"family" ~static_args_key:None right;
  Constructor_registry.register registry (constructor_entry left "left" Constructor_registry.Emitted);
  (match Constructor_registry.family_coverage registry ~source_category:"family" ~static_args_key:None with
  | Open _ -> ()
  | Closed _ -> failwith "partially represented constructor family was marked closed");
  Constructor_registry.register registry (constructor_entry right "right" Constructor_registry.Emitted);
  match Constructor_registry.family_coverage registry ~source_category:"family" ~static_args_key:None with
  | Closed entries when List.length entries = 2 -> ()
  | Closed _ -> failwith "closed constructor family lost an alternative"
  | Open blockers -> failwith ("complete constructor family stayed open: " ^ String.concat "; " blockers)

let test_open_length_guarded_constructor_is_refutable () =
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let category = "renamed_open_length_guard" in
  let registry = Context.constructors ctx in
  let entry = length_guarded_entry category in
  Constructor_registry.note_source_case registry
    ~source_category:entry.source_category ~static_args_key:None
    (origin "open-length-guard-left");
  Constructor_registry.note_source_case registry
    ~source_category:entry.source_category ~static_args_key:None
    (origin "open-length-guard-right");
  Constructor_registry.register registry entry;
  let sequence_typ = IterT (nat_typ, List) $ region in
  let category_typ = VarT (id category, []) $ region in
  let pattern =
    CaseE (mixop, typed_var sequence_typ "open_payload")
    $$ region % category_typ
  in
  if Runtime_truth_total_equality.certified_binding_pattern ctx [] pattern then
    failwith "open constructor family was certified by one length-guarded case"

let test_constructor_family_static_key_isolation () =
  let registry = Constructor_registry.create () in
  let case_origin = origin "family-generic-case" in
  Constructor_registry.note_source_case
    registry ~source_category:"family" ~static_args_key:None case_origin;
  Constructor_registry.register registry
    { (constructor_entry case_origin "specialized-a" Constructor_registry.Emitted) with
      static_args_key = Some "A"
    };
  match
    Constructor_registry.family_coverage
      registry ~source_category:"family" ~static_args_key:(Some "B")
  with
  | Open _ -> ()
  | Closed _ ->
    failwith
      "a generic source case was closed by an unrelated static-key specialization"

let list_rule_request =
  { Helper_request.source_shape =
      { prem_source = "all"
      ; body_source = "predicate(head)"
      ; source_source = "xs"
      ; source_typ_source = "nat*"
      ; iter_source = "*"
      }
  ; generator_var = "x"
  ; helper_head_var = "H"
  ; source_tail_var = "T"
  ; source_element_sort = sort "Nat"
  ; captures = []
  ; body_conditions = [ RewriteCond (App ("p", [ Var "H" ]), Const "ok") ]
  }

let test_list_rule_traversal () =
  let request =
    { Helper_request.kind = Iter_premise_list_rule list_rule_request
    ; reason = "regression"
    ; origin = origin "list-rule"
    }
  in
  let entry = { Helper_registry.name = "allRule"; request } in
  let statements =
    Helper_materialize_iter.materialize_iter_premise_list_rule
      entry list_rule_request
  in
  let ok = Naming.helper_companion ~role:"premise-all-ok" entry.name in
  let recursive = App ("allRule", [ App ("_ _", [ Var "H"; Var "T" ]) ]) in
  let traverses =
    List.exists
      (fun generated ->
        match generated.node with
        | Crl (_, lhs, Const result, conditions)
          when lhs = recursive && result = ok ->
          List.mem (RewriteCond (App ("p", [ Var "H" ]), Const "ok")) conditions
          && List.mem (RewriteCond (App ("allRule", [ Var "T" ]), Const ok)) conditions
        | _ -> false)
      statements
  in
  if not traverses then
    failwith "rewrite-backed list premise does not check head and recursive tail";
  if not
       (List.exists
          (fun generated ->
            match generated.node with
            | OpDecl { name = "allRule"; attrs = [ Frozen [ 1 ] ]; _ } -> true
            | _ -> false)
          statements)
  then failwith "rewrite-backed list helper input is not frozen";
  if not
       (List.exists
          (fun generated ->
            match generated.node with
            | Crl (_, lhs, _,
                   [ RewriteCond (App ("p", [ Var "H" ]), Const "ok")
                   ; RewriteCond (App ("allRule", [ Var "T" ]), Const result)
                   ]) when lhs = recursive && result = ok -> true
            | _ -> false)
          statements)
  then failwith "rewrite-backed list conditions changed order or recursion is not last"

let test_zip_rule_order_and_frozen () =
  let source id head tail : Helper_request.iter_zip_source =
    { source_shape =
        { generator_source_id = id
        ; source_source = id ^ "s"
        ; source_typ_source = "nat*"
        }
    ; source_item_shape = Source_flat_terminal
    ; helper_head_var = head
    ; source_tail_var = tail
    ; source_element_sort = sort "Nat"
    }
  in
  let sources = [ source "left" "LH" "LT"; source "right" "RH" "RT" ] in
  let capture : Helper_request.capture =
    { source_id = "capture"
    ; call_term = Var "CAPTURE"
    ; formal_var = "C"
    ; sort = sort "Nat"
    ; typ = nat_typ
    }
  in
  let body_conditions =
    [ RewriteCond (App ("truth", [ Var "LH" ]), Var "W")
    ; EqCondition (BoolCond (App ("check", [ Var "W"; Var "RH"; Var "C" ])))
    ; EqCondition (BoolCond (App ("captureReady", [ Var "C" ])))
    ]
  in
  let body_conditions =
    Condition_closure.normalize_rule_conditions
      [ Var "LH"; Var "RH"; Var "C" ] body_conditions
  in
  if
    body_conditions
    <> [ RewriteCond (App ("truth", [ Var "LH" ]), Var "W")
       ; EqCondition
           (BoolCond (App ("check", [ Var "W"; Var "RH"; Var "C" ])))
       ; EqCondition (BoolCond (App ("captureReady", [ Var "C" ])))
       ]
  then failwith "rule-condition scheduler moved a later ready guard before the earliest producer";
  let prem : Helper_request.iter_premise_zip_rule =
    { source_shape =
        { prem_source = "zip"
        ; body_source = "truth(left) => W /\\ check(W,right,capture)"
        ; iter_source = "*"
        ; sources =
            List.map
              (fun (source : Helper_request.iter_zip_source) ->
                source.source_shape)
              sources
        }
    ; sources
    ; captures = [ capture ]
    ; body_conditions
    }
  in
  let request =
    { Helper_request.kind = Iter_premise_zip_rule prem
    ; reason = "regression"
    ; origin = origin "zip-rule"
    }
  in
  let statements =
    Helper_materialize_iter.materialize_iter_premise_zip_rule
      { Helper_registry.name = "zipRule"; request } prem
  in
  let ok = Naming.helper_companion ~role:"premise-zip-ok" "zipRule" in
  if not
       (List.exists
          (fun generated ->
            match generated.node with
            | OpDecl { name = "zipRule"; attrs = [ Frozen [ 1; 2; 3 ] ]; _ } -> true
            | _ -> false)
          statements)
  then failwith "rewrite-backed zip inputs/capture are not all frozen";
  let expected =
    body_conditions
    @ [ RewriteCond
          (App ("zipRule", [ Var "LT"; Var "RT"; Var "C" ]),
           Const ok) ]
  in
  if not
       (List.exists
          (fun generated ->
            match generated.node with
            | Crl (_, _, Const result, conditions) when result = ok -> conditions = expected
            | _ -> false)
          statements)
  then
    failwith
      "rewrite-backed zip did not preserve RewriteCond binding order with recursion last"

let test_recursive_rule_condition_progress_order () =
  let lhs = App ("recursiveSchedule", [ Var "STATE" ]) in
  let recursive = RewriteCond (lhs, Var "RESULT") in
  let guard =
    EqCondition (BoolCond (App ("progress", [ Var "STATE" ])))
  in
  if
    Condition_closure.normalize_rule_conditions
      [ lhs ] [ recursive; guard ]
    <> [ guard; recursive ]
  then failwith "self-recursive RewriteCond ran before an LHS-bound progress guard";
  let producing_recursive = RewriteCond (lhs, Var "NEXT") in
  let dependent =
    EqCondition (BoolCond (App ("observe", [ Var "NEXT" ])))
  in
  if
    Condition_closure.normalize_rule_conditions
      [ lhs ] [ producing_recursive; dependent ]
    <> [ producing_recursive; dependent ]
  then failwith "recursive RewriteCond consumer moved before its witness producer";
  let binding = EqCondition (EqCond (Var "BOUND", Var "STATE")) in
  let normalized_binding =
    EqCondition (MatchCond (Var "BOUND", Var "STATE"))
  in
  if
    Condition_closure.normalize_rule_conditions
      [ lhs ] [ recursive; binding ]
    <> [ recursive; normalized_binding ]
  then failwith "binding equality was promoted before a self-recursive RewriteCond"

let test_zip_binding_traversal () =
  let source : Helper_request.iter_zip_source =
    { source_shape =
        { generator_source_id = "x"
        ; source_source = "xs"
        ; source_typ_source = "nat*"
        }
    ; source_item_shape = Source_flat_terminal
    ; helper_head_var = "H"
    ; source_tail_var = "T"
    ; source_element_sort = sort "Nat"
    }
  in
  let output : Helper_request.iter_premise_binding_output =
    { source_item_shape = Source_flat_terminal
    ; helper_head_var = "O"
    ; source_tail_var = "OT"
    ; source_element_sort = sort "Nat"
    }
  in
  let prem : Helper_request.iter_premise_zip_binding =
    { source_shape =
        { prem_source = "map"
        ; body_source = "O = f(H)"
        ; iter_source = "*"
        ; sources = [ source.source_shape ]
        }
    ; sources = [ source ]
    ; outputs = [ output ]
    ; captures = []
    ; body_eq_conditions = [ MatchCond (Var "O", App ("f", [ Var "H" ])) ]
    }
  in
  let request =
    { Helper_request.kind = Iter_premise_zip_binding prem
    ; reason = "regression"
    ; origin = origin "zip-binding"
    }
  in
  let entry = { Helper_registry.name = "zipBinding"; request } in
  let statements =
    Helper_materialize_iter.materialize_iter_premise_zip_binding entry prem
  in
  let recursive = App ("zipBinding", [ App ("_ _", [ Var "H"; Var "T" ]) ]) in
  let traverses =
    List.exists
      (fun generated ->
        match generated.node with
        | Ceq (lhs, _, conditions, _) when lhs = recursive ->
          List.mem (MatchCond (Var "O", App ("f", [ Var "H" ]))) conditions
          && List.exists
               (function
                 | MatchCond (_, App ("zipBinding", [ Var "T" ])) -> true
                 | _ -> false)
               conditions
        | _ -> false)
      statements
  in
  if not traverses then
    failwith "multi-output zip binding does not preserve head binding and recursive tail"

let test_builtin_dependency_readiness () =
  let backend = Builtin_backend.load () in
  let requirement key =
    match Builtin_backend.find backend key with
    | Some requirement -> requirement
    | None -> failwith ("missing backend requirement " ^ key)
  in
  if Builtin_backend.dependencies (requirement "frelaxed_madd_")
     <> [ "fmul_"; "fadd_" ] then
    failwith "builtin dependency metadata was not loaded from the contract";
  if Builtin_backend.totality (requirement "inv_concat_")
     <> Builtin_backend.Partial then
    failwith "inverse partiality was not loaded from the backend contract"

let ingress_bool_typ = BoolT $ region
let ingress_seq_typ = IterT (nat_typ, List) $ region

let ingress_var text typ = VarE (id text) $$ region % typ

let ingress_fixture ?(runtime_use = false) ?(synthesized = false)
    ?(synthesized_alias = false) ?(mixed_guard = false)
    ?(all_ingress_conjuncts = false) ?(real_clause = false) () =
  let declaration_id = id "renamed_codec" in
  let category_id = id "renamed_ingress" in
  let payload_id = id "renamed_payload" in
  let payload = ingress_var payload_id.it ingress_seq_typ in
  let call =
    CallE (declaration_id, [ ExpA payload $ region ])
    $$ region % ingress_seq_typ
  in
  let length = LenE call $$ region % nat_typ in
  let bound = NumE (`Nat (Z.of_int 16)) $$ region % nat_typ in
  let condition = CmpE (`LtOp, `NatT, length, bound) $$ region % ingress_bool_typ in
  let condition =
    if mixed_guard then
      let runtime_length = LenE payload $$ region % nat_typ in
      let runtime_guard =
        CmpE (`LtOp, `NatT, runtime_length, bound) $$ region % ingress_bool_typ
      in
      BinE (`AndOp, `BoolT, condition, runtime_guard) $$ region % ingress_bool_typ
    else if all_ingress_conjuncts then
      BinE (`AndOp, `BoolT, condition, condition) $$ region % ingress_bool_typ
    else condition
  in
  let premise = IfPr condition $ region in
  let source_clause =
    DefD ([], [ ExpA payload $ region ], payload, []) $ region
  in
  let declaration =
    DecD
      (declaration_id,
       [ ExpP (payload_id, ingress_seq_typ) $ region ],
       ingress_seq_typ,
       if real_clause then [ source_clause ] else [])
    $ region
  in
  let typcase_typ = TupT [ payload_id, ingress_seq_typ ] $ region in
  let category =
    let body = VariantT [ mixop, (typcase_typ, [], [ premise ]), [] ] $ region in
    let inst = InstD ([], [], body) $ region in
    TypD (category_id, [], [ inst ]) $ region
  in
  let runtime_consumer =
    let clause = DefD ([], [], call, []) $ region in
    DecD (id "renamed_runtime_consumer", [], ingress_seq_typ, [ clause ]) $ region
  in
  let category_typ = VarT (category_id, []) $ region in
  let synthesized_consumer =
    let value = ingress_var "renamed_value" category_typ in
    let clause = DefD ([], [], value, []) $ region in
    DecD (id "renamed_category_producer", [], category_typ, [ clause ]) $ region
  in
  let alias_id = id "renamed_runtime_alias" in
  let alias_typ = VarT (alias_id, []) $ region in
  let alias_category =
    let body = AliasT category_typ $ region in
    TypD (alias_id, [], [ InstD ([], [], body) $ region ]) $ region
  in
  let alias_consumer =
    let value = ingress_var "renamed_alias_value" alias_typ in
    DecD
      (id "renamed_alias_producer", [], alias_typ,
       [ DefD ([], [], value, []) $ region ])
    $ region
  in
  let extras =
    (if runtime_use then [ runtime_consumer ] else [])
    @ (if synthesized then [ synthesized_consumer ] else [])
    @ (if synthesized_alias then [ alias_category; alias_consumer ] else [])
  in
  declaration :: category :: extras, category_id.it, premise

let ingress_discharge script category_id premise =
  let analysis =
    script
    |> Analysis.Source_index.of_script
    |> Runtime_ingress_validation.of_source_index
  in
  Runtime_ingress_validation.find
    analysis ~category_id:(Naming.source_slug category_id) premise

let test_runtime_ingress_validation () =
  let script, category_id, premise = ingress_fixture () in
  (match ingress_discharge script category_id premise with
  | Some { declarations = [ "renamed_codec" ] } -> ()
  | _ -> failwith "alpha-renamed ingress-only declaration was not discharged");
  let script, category_id, premise = ingress_fixture ~runtime_use:true () in
  if Option.is_some (ingress_discharge script category_id premise) then
    failwith "declaration with a runtime CallE use was discharged";
  let script, category_id, premise = ingress_fixture ~synthesized:true () in
  if Option.is_some (ingress_discharge script category_id premise) then
    failwith "well-formedness premise on a synthesized category was discharged";
  let script, category_id, premise = ingress_fixture ~real_clause:true () in
  if Option.is_some (ingress_discharge script category_id premise) then
    failwith "DecD source clauses did not take precedence over ingress discharge";
  let script, category_id, premise = ingress_fixture ~mixed_guard:true () in
  if Option.is_some (ingress_discharge script category_id premise) then
    failwith "mixed ingress/runtime conjunction erased its runtime guard";
  let script, category_id, premise = ingress_fixture ~all_ingress_conjuncts:true () in
  if Option.is_none (ingress_discharge script category_id premise) then
    failwith "all-ingress conjunction was not discharged as a whole";
  let script, category_id, premise = ingress_fixture ~synthesized_alias:true () in
  if Option.is_some (ingress_discharge script category_id premise) then
    failwith "alias-enclosed synthesized category was treated as ingress-only"

let test_head_guard_refutation () =
  let guard = BoolCond (App ("isOpt", [ Var "RENAMED" ])) in
  (match Runtime_truth_head_guard_refutation.complement
           ~bound_terms:[ Var "RENAMED" ] [ guard ] with
  | Complete [ [ EqCond (term, Const "false") ] ]
    when term = App ("isOpt", [ Var "RENAMED" ]) -> ()
  | _ -> failwith "matched-head false guard lacks a refutation alternative");
  let sequence_guard =
    BoolCond
      (App
         ("typecheckSeq",
          [ App ("_ _", [ Var "HEAD"; Var "TAIL" ]); Const "syn.item" ]))
  in
  (match Runtime_truth_head_guard_refutation.complement
           ~bound_terms:[ Var "HEAD"; Var "TAIL" ] [ sequence_guard ] with
  | Complete [ [ EqCond (term, Const "false") ] ]
    when term =
         App
           ("typecheckSeq",
            [ App ("_ _", [ Var "HEAD"; Var "TAIL" ]); Const "syn.item" ]) ->
    ()
  | _ -> failwith "total sequence typecheck guard was treated as partial");
  (match Runtime_truth_head_guard_refutation.complement
           ~bound_terms:[ Var "RENAMED" ]
           [ BoolCond (App ("partialGuard", [ Var "RENAMED" ])) ] with
  | Blocked _ -> ()
  | Complete _ -> failwith "partial head Boolean guard was complemented");
  match Runtime_truth_head_guard_refutation.complement
          ~bound_terms:[ Var "RENAMED" ]
          [ MembershipCond (Var "RENAMED", sort "SpectecTerminal") ] with
  | Blocked _ -> ()
  | Complete _ -> failwith "non-complementable head membership guard was accepted"

let expect_missing_certificate_blocked label condition =
  match
    Reld_enabledness_direct_complement.sequential_complement_alternatives
      [ Var "X"; Var "Y" ] [ condition ]
  with
  | Blocked (_ :: _) -> ()
  | Complete _ -> failwith (label ^ " acquired an uncertified complement")
  | Blocked [] -> failwith (label ^ " lost its missing-certificate reason")

let test_missing_condition_certificates_blocked () =
  expect_missing_certificate_blocked
    "EqCond" (EqCond (Var "X", Var "Y"));
  expect_missing_certificate_blocked
    "BoolCond" (BoolCond (App ("partialGuard", [ Var "X" ])));
  expect_missing_certificate_blocked
    "literal MatchCond" (MatchCond (Const "0", Var "X"))

let test_head_domain_factoring () =
  let registry = Constructor_registry.create () in
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let env =
    Expr_env.add Expr_env.empty "p"
      { term = Var "P"; sort = sort "Nat"; typ = nat_typ }
  in
  let predecessor_head =
    [ BoolCond (App ("typecheckHead", [ Var "P" ])) ]
  in
  let domain =
    [ MatchCond (Var "OUTPUT", App ("totalView", [ Var "P" ]))
    ; BoolCond (App ("typecheckPayload", [ Var "OUTPUT" ]))
    ]
  in
  let source_condition =
    CmpE (`LtOp, `NatT, var "p", nat 1) $$ region % (BoolT $ region)
  in
  let source_result =
    Premise_translate.translate_premises
      ctx env ~bound_terms:[ Var "P" ] (origin "head-domain-source")
      [ IfPr source_condition $ region ]
    |> complete_premise "head-domain-source"
  in
  let source = Premise_result.eq_conditions source_result in
  if Premise_result.source_condition_certificates source_result = [] then
    failwith "head-domain source IfPr did not produce an AST proof certificate";
  let certificate =
    match Premise_result.source_condition_certificates source_result with
    | certificate :: _ -> certificate
    | [] -> failwith "head-domain source certificate disappeared"
  in
  let complete =
    Reld_enabledness_direct_complement.direct_complement_alternatives
      registry
      ~origin:(origin "head-domain-factoring")
      ~helper_name:"HeadDomain"
      ~current_head_conditions:
        [ BoolCond (App ("typecheckHead", [ Var "X" ])) ]
      ~predecessor_head_conditions:predecessor_head
      ~condition_blocks:
        [ Head_domain_conditions domain; Source_conditions source ]
      ~head_domain_failures:[]
      ~condition_certificates:[ certificate ]
      ~condition_failures:[]
      [ Var "X" ] [ Var "P" ] (domain @ source)
  in
  (match complete with
  | Complete { alternatives = [ alternative ]; _ } ->
    let required_prefix =
      [ EqCondition (BoolCond (App ("typecheckHead", [ Var "X" ])))
      ; EqCondition
          (MatchCond (Var "OUTPUT", App ("totalView", [ Var "X" ])))
      ; EqCondition
          (BoolCond (App ("typecheckPayload", [ Var "OUTPUT" ])))
      ]
    in
    let rec has_prefix prefix values =
      match prefix, values with
      | [], _ -> true
      | expected :: prefix, actual :: values when expected = actual ->
        has_prefix prefix values
      | _ -> false
    in
    if not (has_prefix required_prefix alternative)
       || List.length alternative <= List.length required_prefix
    then
      failwith "head/domain guards were negated or reordered as source failures"
  | Complete _ -> failwith "head-domain factoring emitted an unexpected branch count"
  | Blocked reasons ->
    failwith
      ("structurally certified head-domain factoring was blocked: "
       ^ String.concat "; " reasons));
  match
    Reld_enabledness_direct_complement.direct_complement_alternatives
      registry
      ~origin:(origin "head-domain-unproved")
      ~helper_name:"HeadDomainUnproved"
      ~current_head_conditions:[]
      ~predecessor_head_conditions:predecessor_head
      ~condition_blocks:
        [ Head_domain_conditions domain
        ; Source_conditions [ BoolCond (App ("partialPremise", [ Var "P" ])) ]
        ]
      ~head_domain_failures:[]
      ~condition_certificates:[]
      ~condition_failures:[]
      [ Var "X" ] [ Var "P" ]
      (domain @ [ BoolCond (App ("partialPremise", [ Var "P" ])) ])
  with
  | Blocked (_ :: _) -> ()
  | Blocked [] -> failwith "unproved source premise lost its blocker"
  | Complete _ -> failwith "factored head guards masked an unproved Bool premise"

let test_source_ifpr_total_observers () =
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let env =
    Expr_env.empty
    |> fun env -> Expr_env.add env "x"
         { term = Var "X"; sort = sort "Nat"; typ = nat_typ }
    |> fun env -> Expr_env.add env "y"
         { term = Var "Y"; sort = sort "Nat"; typ = nat_typ }
  in
  let check name condition =
    let result =
      Premise_translate.translate_premises
        ctx env ~bound_terms:[ Var "X"; Var "Y" ] (origin name)
        [ IfPr condition $ region ]
      |> complete_premise name
    in
    if List.exists Diagnostics.is_fatal (Premise_result.diagnostics result) then
      failwith (name ^ " source IfPr did not lower");
    match
      Reld_enabledness_direct_complement
      .certified_sequential_complement_alternatives
        (Context.constructors ctx)
        ~origin:(origin name)
        ~helper_name:name
        ~condition_certificates:
          (Premise_result.source_condition_certificates result)
        ~condition_failures:(Premise_result.source_condition_failures result)
        [ Var "X"; Var "Y" ] (Premise_result.eq_conditions result)
    with
    | Complete { alternatives = [ _ ]; _ } -> ()
    | Complete _ -> failwith (name ^ " did not produce exactly one false branch")
    | Blocked reasons ->
      failwith (name ^ " total source observer was blocked: "
                ^ String.concat "; " reasons)
  in
  let bool_typ = BoolT $ region in
  check "source-total-bool"
    (CmpE (`LtOp, `NatT, var "x", var "y") $$ region % bool_typ);
  check "source-total-equality"
    (CmpE (`EqOp, `NatT, var "x", var "y") $$ region % bool_typ)

let test_incomplete_sequential_complement_rejected () =
  let first = MembershipCond (Var "X", sort "SpectecTerminal") in
  let second = EqCond (Var "X", Var "Y") in
  match
    Reld_enabledness_direct_complement.sequential_complement_alternatives
      [ Var "X"; Var "Y" ] [ first; second ]
  with
  | Blocked (_ :: _) -> ()
  | Complete { alternatives; _ } ->
    failwith
      ("incomplete first failure leaked " ^ string_of_int (List.length alternatives)
       ^ " partial alternatives")
  | Blocked [] -> failwith "incomplete complement lost its structured reason"

let total_sequence_definition name element_typ =
  let sequence_typ = IterT (element_typ, List) $ region in
  let input = var "state" in
  let clause =
    DefD
      ([], [ ExpA input $ region ],
       ListE [] $$ region % sequence_typ, [])
    $ region
  in
  DecD
    (id name, [ ExpP (id "state", nat_typ) $ region ],
     sequence_typ, [ clause ])
  $ region

let test_source_indexed_equality_certificate () =
  let entry_typ = VarT (id "entry", []) $ region in
  let tag_atom =
    Xl.Atom.Atom "TAG" $$ region % Xl.Atom.info "entry"
  in
  let entry_definition =
    let fields = [ tag_atom, (nat_typ, [], []), [] ] in
    let instance = InstD ([], [], StructT fields $ region) $ region in
    TypD (id "entry", [], [ instance ]) $ region
  in
  let left_name = "renamed_entries" in
  let right_name = "renamed_addresses" in
  let script =
    [ entry_definition
    ; total_sequence_definition left_name entry_typ
    ; total_sequence_definition right_name nat_typ
    ]
  in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let binding name =
    { Expr_env.term = Var name; sort = sort "Nat"; typ = nat_typ }
  in
  let env =
    Expr_env.empty
    |> fun env -> Expr_env.add env "state" (binding "STATE")
    |> fun env -> Expr_env.add env "address" (binding "ADDRESS")
    |> fun env -> Expr_env.add env "index" (binding "INDEX")
  in
  let call name typ =
    CallE (id name, [ ExpA (var "state") $ region ]) $$ region % typ
  in
  let entry_sequence_typ = IterT (entry_typ, List) $ region in
  let address_sequence_typ = IterT (nat_typ, List) $ region in
  let entry =
    IdxE (call left_name entry_sequence_typ, var "address")
    $$ region % entry_typ
  in
  let tag =
    DotE (entry, tag_atom) $$ region % nat_typ
  in
  let address =
    IdxE (call right_name address_sequence_typ, var "index")
    $$ region % nat_typ
  in
  let bound_vars = [ "STATE"; "ADDRESS"; "INDEX" ] in
  match
    Runtime_truth_total_equality.source_equality_alternatives
      ~bound_vars ctx env (origin "source-indexed-equality") tag address
  with
  | Error blockers ->
    failwith
      ("source-indexed equality was not structurally certified: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_total_equality.reason)
              blockers))
  | Ok (_, _, _, failures, diagnostics) ->
    if List.exists Diagnostics.is_fatal diagnostics then
      failwith "source-indexed equality certificate retained a fatal lowering";
    if List.length failures <> 3 then
      failwith "source-indexed equality lost an index first-failure alternative";
    let equality =
      CmpE (`EqOp, `NatT, tag, address) $$ region % (BoolT $ region)
    in
    let premise_result =
      Premise_translate.translate_premises
        ctx env
        ~bound_terms:[ Var "STATE"; Var "ADDRESS"; Var "INDEX" ]
        (origin "source-indexed-equality-premise")
        [ IfPr equality $ region ]
      |> complete_premise "source-indexed-equality-premise"
    in
    let positive_conditions = Premise_result.eq_conditions premise_result in
    let certificate =
      match Premise_result.source_condition_certificates premise_result with
      | certificate :: _ -> certificate
      | [] ->
        failwith "exact nonbinding source equality MatchCond was not AST-certified"
    in
    (match
       Reld_enabledness_direct_complement
       .certified_sequential_complement_alternatives
         (Context.constructors ctx)
         ~origin:(origin "source-indexed-equality")
         ~helper_name:"SourceIndexedEquality"
         ~condition_certificates:[ certificate ]
         ~condition_failures:[]
         [ Var "STATE"; Var "ADDRESS"; Var "INDEX" ]
         positive_conditions
     with
    | Complete { alternatives; _ } when List.length alternatives = 3 -> ()
    | Complete _ ->
      failwith "certified source equality emitted an incomplete complement"
    | Blocked reasons ->
      failwith
        ("certified source equality complement was blocked: "
         ^ String.concat "; " reasons))

let test_indexed_equality_then_list_binding_complement () =
  let list_typ = IterT (nat_typ, List) $ region in
  let entry_typ = VarT (id "binding_entry", []) $ region in
  let atom name =
    Xl.Atom.Atom name $$ region % Xl.Atom.info "binding_entry"
  in
  let tag, fields = atom "TAG", atom "FIELDS" in
  let entry_definition =
    let fields =
      [ tag, (nat_typ, [], []), []
      ; fields, (list_typ, [], []), []
      ]
    in
    TypD
      (id "binding_entry", [],
       [ InstD ([], [], StructT fields $ region) $ region ])
    $ region
  in
  let entries = "binding_entries" in
  let addresses = "binding_addresses" in
  let script =
    [ entry_definition
    ; total_sequence_definition entries entry_typ
    ; total_sequence_definition addresses nat_typ
    ]
  in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let binding term sort typ = { Expr_env.term; sort; typ } in
  let env =
    Expr_env.empty
    |> fun env -> Expr_env.add env "state"
         (binding (Var "STATE") (sort "Nat") nat_typ)
    |> fun env -> Expr_env.add env "address"
         (binding (Var "ADDRESS") (sort "Nat") nat_typ)
    |> fun env -> Expr_env.add env "index"
         (binding (Var "INDEX") (sort "Nat") nat_typ)
    |> fun env -> Expr_env.add env "values"
         (binding (Var "VALUES") (sort "SpectecTerminals") list_typ)
  in
  let call name typ =
    CallE (id name, [ ExpA (var "state") $ region ]) $$ region % typ
  in
  let entry_sequence_typ = IterT (entry_typ, List) $ region in
  let entry =
    IdxE (call entries entry_sequence_typ, var "address")
    $$ region % entry_typ
  in
  let left = DotE (entry, tag) $$ region % nat_typ in
  let right =
    IdxE (call addresses list_typ, var "index") $$ region % nat_typ
  in
  let equality =
    IfPr (CmpE (`EqOp, `NatT, left, right) $$ region % (BoolT $ region))
    $ region
  in
  let element = typed_var nat_typ "element" in
  let values = typed_var list_typ "values" in
  let identity =
    IterE
      ( element
      , (List, [ id "element", values ]) )
    $$ region % list_typ
  in
  let field_values = DotE (entry, fields) $$ region % list_typ in
  let binding_premise =
    IfPr
      (CmpE (`EqOp, `NatT, identity, field_values)
       $$ region % (BoolT $ region))
    $ region
  in
  let result =
    Premise_translate.translate_premises
      ctx env ~bound_terms:[ Var "STATE"; Var "ADDRESS"; Var "INDEX" ]
      (origin "indexed-equality-list-binding")
      [ equality; binding_premise ]
    |> complete_premise "indexed-equality-list-binding"
  in
  let conditions = Premise_result.eq_conditions result in
  let rec term_has_values = function
    | Var "VALUES" -> true
    | App (_, args) -> List.exists term_has_values args
    | Var _ | Const _ | Qid _ -> false
  in
  let condition_has_values = function
    | EqCond (left, right) | MatchCond (left, right) ->
      term_has_values left || term_has_values right
    | BoolCond term | MembershipCond (term, _) -> term_has_values term
  in
  let index_domain = function
    | BoolCond (App ("indexDefined", _)) -> true
    | EqCond _ | MatchCond _ | BoolCond _ | MembershipCond _ -> false
  in
  let equality_condition = function
    | EqCond _ | MatchCond _ -> true
    | BoolCond _ | MembershipCond _ -> false
  in
  let left_domain, right_domain =
    match conditions with
    | left :: right :: equality :: repeated :: _
      when index_domain left && index_domain right
           && equality_condition equality && repeated = left && left <> right ->
      left, right
    | _ ->
      failwith
        "indexed equality/list binding did not preserve left-domain, right-domain, equality, repeated-RHS-domain order"
  in
  (match List.rev conditions with
  | MatchCond (Var "VALUES", _) :: _ -> ()
  | _ -> failwith "identity List equality did not end in a fresh binding MatchCond");
  if
    conditions
    |> List.exists (function
      | EqCond (left, right)
      | BoolCond (App ("_=/=_", [ left; right ])) ->
        term_has_values left || term_has_values right
      | MatchCond _ | BoolCond _ | MembershipCond _ -> false)
  then
    failwith "fresh List binding was lowered as a value disequality";
  match
    Reld_enabledness_direct_complement
    .certified_sequential_complement_alternatives
      (Context.constructors ctx)
      ~origin:(origin "indexed-equality-list-binding")
      ~helper_name:"IndexedEqualityListBinding"
      ~condition_certificates:
        (Premise_result.source_condition_certificates result)
      ~condition_failures:(Premise_result.source_condition_failures result)
      [ Var "STATE"; Var "ADDRESS"; Var "INDEX" ] conditions
  with
  | Complete { alternatives = [ first; second; third ] as alternatives; _ } ->
    let has condition =
      List.exists (function
        | EqCondition actual -> actual = condition
        | RewriteCond _ -> false)
    in
    let negated = function
      | BoolCond term -> BoolCond (App ("not_", [ term ]))
      | EqCond _ | MatchCond _ | MembershipCond _ ->
        failwith "indexed source domain was not emitted as a Bool condition"
    in
    let has_disequality =
      List.exists (function
        | EqCondition (BoolCond (App ("_=/=_", _))) -> true
        | EqCondition _ | RewriteCond _ -> false)
    in
    if
      not
        (has (negated left_domain) first
         && has left_domain second && has (negated right_domain) second
         && has left_domain third && has right_domain third
         && has_disequality third)
    then
      failwith "indexed equality failure branches lost source first-failure order";
    if
      alternatives
      |> List.concat
      |> List.exists (function
        | EqCondition condition -> condition_has_values condition
        | RewriteCond (left, right) ->
          term_has_values left || term_has_values right)
    then
      failwith "List binding escaped into an ElsePr failure branch"
  | Complete { alternatives; _ } ->
    failwith
      ("indexed equality plus binding produced "
       ^ string_of_int (List.length alternatives) ^ " failure branches")
  | Blocked reasons ->
    failwith
      ("indexed equality plus List binding complement was blocked: "
       ^ String.concat "; " reasons)

let test_irrefutable_binding_patterns () =
  let list_typ = IterT (nat_typ, List) $ region in
  let opt_typ = IterT (nat_typ, Opt) $ region in
  let int_typ = NumT `IntT $ region in
  let rat_typ = NumT `RatT $ region in
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let certified ?(bound = []) pattern =
    Runtime_truth_total_equality.certified_binding_pattern ctx bound pattern
  in
  let element = typed_var nat_typ "binding_element" in
  let values = typed_var list_typ "binding_values" in
  let identity =
    IterE (element, (List, [ id "binding_element", values ]))
    $$ region % list_typ
  in
  if not (certified identity) then
    failwith "exact identity List iteration binding was not certified";
  if certified ~bound:[ "binding_values" ] identity then
    failwith "identity List iteration accepted an already-bound pattern source";
  let nonidentity =
    IterE
      (typed_var nat_typ "other_element",
       (List, [ id "binding_element", values ]))
    $$ region % list_typ
  in
  if certified nonidentity then
    failwith "non-identity List iteration was certified as irrefutable";
  if certified (ListE [ typed_var nat_typ "fixed" ] $$ region % list_typ) then
    failwith "fixed-length ListE pattern was certified as irrefutable";
  if certified (OptE (Some (typed_var nat_typ "present")) $$ region % opt_typ) then
    failwith "present OptE pattern was certified as irrefutable";
  if certified (OptE None $$ region % opt_typ) then
    failwith "empty OptE pattern was certified as irrefutable";
  if
    certified
      (CvtE (typed_var nat_typ "converted", `NatT, `RatT)
       $$ region % rat_typ)
  then failwith "non-representation-preserving CvtE was certified as irrefutable";
  if
    certified
      (SubE (typed_var nat_typ "subtyped", nat_typ, int_typ)
       $$ region % int_typ)
  then failwith "guarded SubE was certified as irrefutable"

let test_unproven_matchcond_complement_rejected () =
  let condition =
    MatchCond (App ("partialProjection", [ Var "X" ]), Var "Y")
  in
  match
    Reld_enabledness_direct_complement.sequential_complement_alternatives
      [ Var "X"; Var "Y" ] [ condition ]
  with
  | Blocked (_ :: _) -> ()
  | Complete _ -> failwith "unproven partial MatchCond acquired a false complement"
  | Blocked [] -> failwith "unproven MatchCond lost its structured blocker"

let test_stuck_call_cannot_refute_equality () =
  let declaration =
    DecD
      (id "renamed_stuck", [ ExpP (id "input", nat_typ) $ region ],
       nat_typ, [])
    $ region
  in
  let index = Analysis.Source_index.of_script [ declaration ] in
  let builtins = Builtin_registry.of_source_index index in
  let ctx = Context.create index builtins in
  let env =
    Expr_env.add Expr_env.empty "x"
      { term = Var "X"; sort = sort "Nat"; typ = nat_typ }
  in
  let call =
    CallE (id "renamed_stuck", [ ExpA (var "x") $ region ])
    $$ region % nat_typ
  in
  match
    Runtime_truth_total_equality.false_conditions
      ctx env (origin "stuck-totality") `EqOp call (nat 0)
  with
  | Error blockers
    when List.exists (fun blocker ->
      blocker.Runtime_truth_total_equality.constructor
      = "RuntimeTruthTotalEquality/CallE/clause-free-call") blockers -> ()
  | Error _ -> failwith "stuck equality reported an imprecise totality blocker"
  | Ok _ -> failwith "clause-free call was treated as false by inequality"

let test_iter_evaluator_domains () =
  let list_typ = IterT (nat_typ, List) $ region in
  let list values = ListE (List.map nat values) $$ region % list_typ in
  let generator name = id name in
  let body name = VarE (id name) $$ region % nat_typ in
  let iter iterator generators body =
    IterE (body, (iterator, generators)) $$ region % list_typ
  in
  let zip_mismatch =
    iter List
      [ generator "left", list [ 0 ]
      ; generator "right", list []
      ]
      (body "left")
  in
  let empty_list1 =
    iter List1 [ generator "item", list [] ] (body "item")
  in
  let listn_mismatch =
    iter (ListN (nat 2, None))
      [ generator "item", list [ 0 ] ] (body "item")
  in
  let stuck_count_decl =
    DecD (id "renamed_count", [], nat_typ, []) $ region
  in
  let stuck_count =
    CallE (id "renamed_count", []) $$ region % nat_typ
  in
  let listn_stuck_count =
    iter (ListN (stuck_count, None))
      [ generator "item", list [ 0 ] ] (body "item")
  in
  let nested_partial =
    iter List [ generator "nested", listn_mismatch ] (body "nested")
  in
  let zero_generator_indexed =
    iter (ListN (nat 2, Some (id "standalone_index"))) []
      (body "standalone_index")
  in
  let check_direct name script exp expected =
    let index = Analysis.Source_index.of_script script in
    let ctx = Context.create index (Builtin_registry.of_source_index index) in
    match
      Runtime_truth_total_equality.false_conditions
        ctx Expr_env.empty (origin (name ^ "-direct"))
        `EqOp exp (list [])
    with
    | Error blockers
      when List.exists
             (fun blocker ->
               blocker.Runtime_truth_total_equality.constructor = expected)
             blockers -> ()
    | Error blockers ->
      failwith
        (name ^ " direct IterE had the wrong blocker: "
         ^ String.concat "; "
             (List.map
                (fun blocker -> blocker.Runtime_truth_total_equality.constructor)
                blockers))
    | Ok _ -> failwith (name ^ " direct IterE was admitted as total")
  in
  let check_call name extra_declarations exp expected =
    let wrapper =
      DecD
        (id (name ^ "_wrapper"), [], list_typ,
         [ DefD ([], [], exp, []) $ region ])
      $ region
    in
    let index =
      Analysis.Source_index.of_script (extra_declarations @ [ wrapper ])
    in
    let ctx = Context.create index (Builtin_registry.of_source_index index) in
    let call =
      CallE (id (name ^ "_wrapper"), []) $$ region % list_typ
    in
    match
      Runtime_truth_total_equality.false_conditions
        ctx Expr_env.empty (origin (name ^ "-call"))
        `EqOp call (list [])
    with
    | Error blockers
      when List.exists
             (fun blocker ->
               blocker.Runtime_truth_total_equality.constructor = expected)
             blockers -> ()
    | Error _ -> failwith (name ^ " CallE lost its iterator-domain blocker")
    | Ok _ -> failwith (name ^ " CallE was certified through a partial IterE")
  in
  let iteration_blocker =
    "RuntimeTruthTotalEquality/IterE/iteration-domain"
  in
  List.iter
    (fun (name, declarations, exp, expected) ->
      check_direct name declarations exp expected;
      check_call name declarations exp expected)
    [ "zip-mismatch", [], zip_mismatch, iteration_blocker
    ; "empty-list1", [], empty_list1, iteration_blocker
    ; "listn-mismatch", [], listn_mismatch, iteration_blocker
    ; ( "listn-stuck-count"
      , [ stuck_count_decl ]
      , listn_stuck_count
      , "RuntimeTruthTotalEquality/CallE/clause-free-call" )
    ; "nested-partial", [], nested_partial, iteration_blocker
    ; "zero-generator-indexed", [], zero_generator_indexed, iteration_blocker
    ];
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let same_pair (left, right) (actual_left, actual_right) =
    (left = actual_left && right = actual_right)
    || (left = actual_right && right = actual_left)
  in
  let positive_equality = function
    | EqCond (left, right) | MatchCond (left, right)
    | BoolCond (App ("_==_", [ left; right ])) -> Some (left, right)
    | BoolCond _ | MembershipCond _ -> None
  in
  let negative_equality = function
    | BoolCond (App ("not_", [ App ("_==_", [ left; right ]) ]))
    | BoolCond (App ("_=/=_", [ left; right ])) -> Some (left, right)
    | EqCond _ | MatchCond _ | BoolCond _ | MembershipCond _ -> None
  in
  let contradictory conditions =
    let positives = List.filter_map positive_equality conditions in
    let negatives = List.filter_map negative_equality conditions in
    List.exists
      (fun positive -> List.exists (same_pair positive) negatives)
      positives
  in
  let check_alternatives name exp =
    match
      Runtime_truth_total_equality.source_equality_alternatives
        ctx Expr_env.empty (origin (name ^ "-domain-alternatives"))
        exp (list [])
    with
    | Ok (_, _, _, failures, _) when List.length failures >= 2 ->
      if List.exists contradictory failures then
        failwith
          (name
           ^ " equality prepended a proven positive length guard to its own failure branch")
    | Ok _ ->
      failwith
        (name
         ^ " equality omitted its required iterator-domain failure before disequality")
    | Error blockers ->
      failwith
        (name ^ " equality domain alternatives were not representable: "
         ^ String.concat "; "
             (List.map
                (fun blocker -> blocker.Runtime_truth_total_equality.reason)
                blockers))
  in
  check_alternatives "zip" zip_mismatch;
  check_alternatives "listn" listn_mismatch

let test_clause_proven_indexed_enumeration () =
  let list_typ = IterT (nat_typ, List) $ region in
  let source_id = id "source_items" in
  let element_id = id "source_item" in
  let count_id = id "source_count" in
  let index_id = id "enumerated_index" in
  let source = VarE source_id $$ region % list_typ in
  let count = VarE count_id $$ region % nat_typ in
  let pattern =
    IterE
      ( VarE element_id $$ region % nat_typ
      , (ListN (count, None), [ element_id, source ]) )
    $$ region % list_typ
  in
  let result =
    IterE
      ( VarE index_id $$ region % nat_typ
      , (ListN (count, Some index_id), []) )
    $$ region % list_typ
  in
  let name = "renamed_index_enumeration" in
  let declaration =
    DecD
      ( id name
      , [ ExpP (source_id, list_typ) $ region ]
      , list_typ
      , [ DefD ([], [ ExpA pattern $ region ], result, []) $ region ] )
    $ region
  in
  let index = Analysis.Source_index.of_script [ declaration ] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let input = ListE [ nat 0; nat 1 ] $$ region % list_typ in
  let call =
    CallE (id name, [ ExpA input $ region ]) $$ region % list_typ
  in
  match
    Runtime_truth_total_equality.false_conditions
      ctx Expr_env.empty (origin name) `EqOp call input
  with
  | Ok (_, diagnostics) when not (List.exists Diagnostics.is_fatal diagnostics) -> ()
  | Ok _ -> failwith "clause-proven indexed enumeration retained fatal diagnostics"
  | Error blockers ->
    failwith
      ("source-pattern count proof did not certify indexed enumeration: "
       ^ String.concat "; "
           (List.map
              (fun blocker -> blocker.Runtime_truth_total_equality.reason)
              blockers))

let boolean_worklist_result partial =
  let relation_id = if partial then "partial_boolean" else "total_boolean" in
  let x = var "boolean_input" in
  let observed, declarations =
    if partial then
      let declaration =
        DecD
          (id "renamed_boolean_observer",
           [ ExpP (id "value", nat_typ) $ region ], nat_typ, [])
        $ region
      in
      ( CallE
          (id "renamed_boolean_observer", [ ExpA x $ region ])
        $$ region % nat_typ
      , [ declaration ] )
    else
      x, []
  in
  let condition =
    CmpE (`LtOp, `NatT, observed, nat 1) $$ region % (BoolT $ region)
  in
  let head = TupE [ x; x ] $$ region % nat_typ in
  let rule =
    source_rule "boolean-guard" head [ IfPr condition $ region ]
  in
  let script =
    runtime_script
      (declarations @ [ relation_def relation_id [ rule ] ])
      relation_id
  in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let plan = Runtime_truth_scc.plan (Context.function_graph ctx) relation_id in
  let classified =
    plan.sccs
    |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
    |> List.exists (fun rule ->
      match rule.Runtime_truth_scc.premises with
      | [ Runtime_truth_scc.Source_boolean { it = IfPr _; _ } ] -> true
      | _ -> false)
  in
  if not classified then
    failwith "non-equality IfPr was not retained as a source Boolean observer";
  let request =
    { Runtime_truth_worklist_helper.relation_id
    ; specialization = "nat,nat"
    ; input_terms = [ Const "0"; Const "0" ]
    ; input_sorts = [ sort "Nat"; sort "Nat" ]
    ; phase = Runtime_truth_scc.Goal
    ; mode = Runtime_truth_worklist_helper.Decide
    ; plan
    }
  in
  Runtime_truth_worklist_materializer.materialize ctx
    [ { name = if partial then "PartialBoolean" else "TotalBoolean"
      ; origin = origin relation_id
      ; request
      } ]

let dependent_false_decision_result partial =
  let dependent_id =
    if partial then "partial_dependent_boolean" else "total_dependent_boolean"
  in
  let root_id =
    if partial then "partial_dependent_root" else "total_dependent_root"
  in
  let x = var "dependent_boolean_input" in
  let observed, declarations =
    if partial then
      let declaration =
        DecD
          ( id "partial_dependent_observer"
          , [ ExpP (id "value", nat_typ) $ region ]
          , nat_typ
          , [] )
        $ region
      in
      ( CallE
          (id "partial_dependent_observer", [ ExpA x $ region ])
        $$ region % nat_typ
      , [ declaration ] )
    else
      x, []
  in
  let condition =
    CmpE (`LtOp, `NatT, observed, nat 1) $$ region % (BoolT $ region)
  in
  let head = TupE [ x; x ] $$ region % nat_typ in
  let dependent_rule =
    source_rule "dependent-boolean" head [ IfPr condition $ region ]
  in
  let dependent_premise =
    RulePr (id dependent_id, [], predicate_mixop, head) $ region
  in
  let root_rule =
    source_rule "dependent-root" head [ dependent_premise ]
  in
  let script =
    runtime_script
      (declarations
       @ [ relation_def dependent_id [ dependent_rule ]
         ; relation_def root_id [ root_rule ]
         ])
      root_id
  in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let closure, rules =
    match
      Analysis.Function_graph.runtime_predicate_truth_plan
        (Context.function_graph ctx) root_id
    with
    | Analysis.Function_graph.Runtime_search_no_shape_blockers
        { closure; rules }
    | Runtime_search_blocked_plan { closure; rules; _ } -> closure, rules
  in
  let truth_request =
    { Runtime_truth_search_helper.rel_id = root_id
    ; input_terms = [ Const "0"; Const "0" ]
    ; input_sorts = [ sort "Nat"; sort "Nat" ]
    ; recursion = Runtime_truth_search_helper.Acyclic
    ; closure
    ; rules
    }
  in
  let request =
    { Runtime_truth_decision_helper.truth_helper_name = "DependentFalseTruth"
    ; truth_request
    }
  in
  ctx,
  Runtime_truth_decision_materializer.materialize ctx
    [ { name = "DependentFalseDecision"
      ; origin = origin root_id
      ; request
      } ]

let test_old_dependent_false_requires_total_boolean () =
  let total_ctx, total = dependent_false_decision_result false in
  (match total with
  | Runtime_truth_decision_materializer.Blocked diagnostics ->
    failwith
      ("total dependent Boolean no-hit route was blocked: "
       ^ String.concat "; "
           (List.map (fun diagnostic -> diagnostic.Diagnostics.reason) diagnostics))
  | Complete complete ->
    if Runtime_truth_decision_materializer.complete_statements complete = [] then
      failwith "total dependent Boolean no-hit route emitted no decision surface");
  ignore total_ctx;
  let partial_ctx, partial = dependent_false_decision_result true in
  (match partial with
  | Runtime_truth_decision_materializer.Complete _ ->
    failwith
      "partial non-equality IfPr completed the obsolete dependent-false route"
  | Blocked diagnostics ->
    if not
         (List.exists
            (fun diagnostic ->
              diagnostic.Diagnostics.constructor
              = "RuntimeTruthTotalEquality/CallE/clause-free-call"
              && Diagnostics.is_fatal diagnostic)
            diagnostics)
    then
      failwith
        ("partial dependent-false route lost its premise-origin totality blocker: "
         ^ String.concat "; "
             (List.map
                (fun diagnostic ->
                  diagnostic.Diagnostics.constructor ^ ": " ^ diagnostic.reason)
                diagnostics)));
  if
    Helper.runtime_predicate_truth_search_requests
      (Context.helpers partial_ctx)
    <> []
    || Helper.runtime_predicate_truth_decision_requests
         (Context.helpers partial_ctx)
       <> []
  then
    failwith
      "blocked dependent-false route registered a dangling nested helper reference"

let test_blocked_indexed_no_hit_is_transactional () =
  let pair_typ = TupT [ id "left", nat_typ; id "right", nat_typ ] $ region in
  let list_typ = IterT (nat_typ, List) $ region in
  let left, right, witness = var "renamed_left", var "renamed_right", var "renamed_witness" in
  let dep_id = "renamed_indexed_dependency" in
  let target_id = "renamed_indexed_target" in
  let root_id = "renamed_indexed_no_hit" in
  let probe_id = "renamed_indexed_probe" in
  let pred relation components =
    RulePr
      (id relation, [], predicate_mixop,
       TupE components $$ region % pair_typ)
    $ region
  in
  let dep_fact =
    source_rule "renamed-dependency-fact"
      (TupE [ left; left ] $$ region % pair_typ) []
  in
  let dep_step =
    source_rule "renamed-dependency-step"
      (TupE [ left; right ] $$ region % pair_typ)
      [ pred dep_id [ left; witness ]
      ; pred target_id [ witness; right ]
      ]
  in
  let target_fact =
    source_rule "renamed-target-fact"
      (TupE [ left; left ] $$ region % pair_typ) []
  in
  let source = typed_var list_typ "renamed_indexed_source" in
  let index = var "renamed_index" in
  let value = var "renamed_indexed_value" in
  let indexed = IdxE (source, index) $$ region % nat_typ in
  let probe_call =
    CallE (id probe_id, [ ExpA value $ region ]) $$ region % nat_typ
  in
  let probe_guard =
    IfPr
      (CmpE (`EqOp, `NatT, probe_call, value)
       $$ region % (BoolT $ region))
    $ region
  in
  let root_rule =
    source_rule "renamed-indexed-root"
      (TupE [ source; value ] $$ region
       % (TupT [ id "source", list_typ; id "value", nat_typ ] $ region))
      [ pred dep_id [ indexed; value ]; probe_guard; ElsePr $ region ]
  in
  let root =
    RelD
      ( id root_id
      , []
      , predicate_mixop
      , TupT [ id "source", list_typ; id "value", nat_typ ] $ region
      , [ root_rule ] )
    $ region
  in
  let script =
    runtime_script
      [ DecD
          ( id probe_id
          , [ ExpP (id "renamed_indexed_probe_input", nat_typ) $ region ]
          , nat_typ
          , [ DefD
                ( []
                , [ ExpA (var "renamed_indexed_probe_input") $ region ]
                , var "renamed_indexed_probe_input"
                , [] )
              $ region
            ] )
        $ region
      ; RelD (id dep_id, [], predicate_mixop, pair_typ, [ dep_fact; dep_step ]) $ region
      ; RelD (id target_id, [], predicate_mixop, pair_typ, [ target_fact ]) $ region
      ; root
      ]
      root_id
  in
  let source_index = Analysis.Source_index.of_script script in
  let ctx = Context.create source_index (Builtin_registry.of_source_index source_index) in
  let nested_ready =
    Runtime_predicate_search.truth_plan ctx dep_id
    |> Runtime_predicate_search.truth_helper_request
         ~input_terms:[ Var "IndexedHead"; Var "IndexedCapture" ]
         ~input_sorts:[ sort "Nat"; sort "Nat" ]
    |> Option.is_some
  in
  if nested_ready then
    failwith
      "legacy no-hit engine accepted a recursive/transitive nested truth helper owned by the SCC worklist";
  let closure, rules =
    match
      Analysis.Function_graph.runtime_predicate_truth_plan
        (Context.function_graph ctx) root_id
    with
    | Runtime_search_no_shape_blockers { closure; rules }
    | Runtime_search_blocked_plan { closure; rules; _ } -> closure, rules
  in
  let truth_request =
    { Runtime_truth_search_helper.rel_id = root_id
    ; input_terms = [ Const "eps"; Const "0" ]
    ; input_sorts = [ sort "SpectecTerminals"; sort "Nat" ]
    ; recursion = Runtime_truth_search_helper.Acyclic
    ; closure
    ; rules
    }
  in
  let request =
    { Runtime_truth_decision_helper.truth_helper_name = "IndexedNoHitTruth"
    ; truth_request
    }
  in
  let registry = Context.helpers ctx in
  let before =
    ( Helper.runtime_predicate_truth_search_requests registry
    , Helper.runtime_predicate_truth_decision_requests registry )
  in
  let provenance_term =
    let probe_ctx =
      Context.create source_index (Builtin_registry.of_source_index source_index)
    in
    let probe_env =
      Expr_env.add Expr_env.empty "renamed_indexed_value"
        { Expr_env.term = Const "0"; sort = sort "Nat"; typ = nat_typ }
    in
    match
      (Expr_translate.lower_value
         probe_ctx probe_env (origin "indexed-no-hit-provenance") probe_call).term
    with
    | Some term
      when Context.definition_call_identities probe_ctx term <> [] -> term
    | Some _ -> failwith "definition-call provenance fixture recorded no identity"
    | None -> failwith "definition-call provenance fixture did not lower its CallE"
  in
  if Context.definition_call_identities ctx provenance_term <> [] then
    failwith "definition-call provenance fixture started dirty";
  let result =
    Runtime_truth_no_hit_materializer.acyclic
      ctx ~helper_name:"IndexedNoHitDecision"
      ~origin:
        (Origin.synthetic
           ~path:[ "runtime-truth"; root_id ]
           ~ast_constructor:"Regression"
           "indexed-no-hit-transaction")
      request
  in
  let diagnostics =
    match result with
    | Runtime_truth_no_hit_materializer.Complete _ ->
      failwith "indexed no-hit fixture unexpectedly completed"
    | Blocked diagnostics -> diagnostics
  in
  if not (List.exists Diagnostics.is_fatal diagnostics) then
    failwith "indexed no-hit fixture did not reach its later fatal premise";
  let blockers = String.concat "; " (List.map (fun diagnostic -> diagnostic.Diagnostics.reason)
                                      diagnostics) in
  if not (contains blockers "dependent RulePr premise") then
    failwith
      ("legacy no-hit ownership rejection lost its dependent RulePr blocker: "
       ^ blockers);
  if
    ( Helper.runtime_predicate_truth_search_requests registry
    , Helper.runtime_predicate_truth_decision_requests registry )
    <> before
  then failwith "blocked indexed no-hit path committed nested helper requests";
  if Context.definition_call_identities ctx provenance_term <> [] then
    failwith "blocked indexed no-hit path committed definition-call provenance";
  if not
       (List.exists
          (fun (diagnostic : Diagnostics.t) ->
            diagnostic.Diagnostics.category = Unsupported
            && diagnostic.severity = Fatal
            && diagnostic.constructor <> ""
            && diagnostic.enclosing <> []
            && diagnostic.profile <> ""
            && Option.is_some diagnostic.suggestion
            && Option.is_some diagnostic.source_echo)
          diagnostics)
  then
    failwith
      ("blocked indexed no-hit diagnostic lost structured provenance fields: "
       ^ Diagnostics.render_all diagnostics);
  if not
       (List.exists
          (fun (diagnostic : Diagnostics.t) ->
            List.mem ("relation " ^ root_id) diagnostic.enclosing
            && List.mem "rule renamed-indexed-root" diagnostic.enclosing
            && List.exists
                 (String.starts_with ~prefix:"source premise ")
                 diagnostic.enclosing)
          diagnostics)
  then
    failwith
      ("blocked indexed no-hit diagnostic lost its source RuleD/premise identity: "
       ^ Diagnostics.render_all diagnostics)

let test_context_stage_isolates_constructor_registry () =
  let source_index = Analysis.Source_index.of_script [] in
  let ctx = Context.create source_index (Builtin_registry.of_source_index source_index) in
  let stage = Context.begin_stage ctx in
  Constructor_registry.register_inclusion
    (Context.constructors (Context.staged stage))
    { parent_category = "renamed-parent"
    ; parent_static_args_key = None
    ; child_category = "renamed-child"
    ; child_static_args_key = None
    ; origin = origin "constructor-stage"
    ; reason = "transaction regression"
    };
  if Constructor_registry.inclusions (Context.constructors ctx) <> [] then
    failwith "uncommitted context stage leaked a constructor inclusion";
  let staged = Context.staged stage in
  let enabledness_request =
    { Runtime_enabledness_helper.relation_id = "staged-relation"
    ; rule_id = None
    ; call_terms = []
    ; predecessor_terms = []
    ; input_sorts = []
    ; lhs_conditions = []
    ; premise_eq_conditions = []
    ; premise_rule_conditions = []
    ; runtime_search_requests = []
    ; runtime_truth_search_requests = []
    ; runtime_truth_decisions = []
    ; runtime_truth_worklist_decisions = []
    ; source_echo = Some "staged runtime item"
    }
  in
  let helper_request =
    { Helper_request.kind =
        Helper_request.Runtime_enabledness enabledness_request
    ; reason = "runtime materialization transaction regression"
    ; origin = origin "runtime-stage-helper"
    }
  in
  ignore (Helper.request (Context.helpers staged) helper_request);
  let staged_call = App ("stagedDefinitionCall", []) in
  Context.record_definition_call staged staged_call
    { Analysis.Function_graph.def_id = "staged-definition"
    ; specialization_key = []
    };
  Constructor_registry.register (Context.constructors staged)
    { source_category = "staged-category"
    ; declaring_category = "staged-category"
    ; static_args_key = None
    ; mixop
    ; arity = 1
    ; constructor_op = "stagedPattern"
    ; projection_ops = []
    ; payload_labels = [ Constructor_registry.Structural_payload ]
    ; payload_witnesses = [ Var "X" ]
    ; payload_sorts = [ sort "Nat" ]
    ; origin = origin "staged-pattern"
    ; enclosing = [ "staged-category" ]
    ; status = Constructor_registry.Emitted
    ; construction_domain = Constructor_registry.Total_constructor
    };
  let staged_certificate =
    Condition_closure.source_constructor_certificate staged
  in
  let target_certificate =
    Condition_closure.source_constructor_certificate ctx
  in
  if not (Condition_pattern_certificate.admits staged_certificate "stagedPattern" 1)
     || Condition_pattern_certificate.admits target_certificate "stagedPattern" 1
  then failwith "rolled-back constructor transaction leaked its pattern certificate"
  else if Helper.runtime_enabledness_requests (Context.helpers ctx) <> [] then
    failwith "rolled-back runtime materialization leaked a helper request"
  else if Context.definition_call_identities ctx staged_call <> [] then
    failwith "rolled-back runtime materialization leaked definition-call provenance"

let test_rejected_ordinary_iterpr_has_no_helper () =
  let list_typ = IterT (nat_typ, List) $ region in
  let source id = typed_var list_typ id in
  let binding term typ sort =
    { Expr_env.term = Var term; sort; typ }
  in
  let run label generators source_bindings bound_vars =
    let source_index = Analysis.Source_index.of_script [] in
    let ctx = Context.create source_index (Builtin_registry.of_source_index source_index) in
    let env =
      source_bindings
      |> List.fold_left
           (fun env (id, term) ->
             Expr_env.add env id
               (binding term list_typ (sort "SpectecTerminals")))
           Expr_env.empty
      |> fun env ->
      Expr_env.add env "renamed_iter_capture"
        (binding "UNBOUND_CAPTURE" nat_typ (sort "Nat"))
    in
    let body =
      IfPr
        (CmpE
           ( `LtOp
           , `NatT
           , var "renamed_iter_head"
           , var "renamed_iter_capture" )
         $$ region % (BoolT $ region))
      $ region
    in
    let prem = IterPr (body, (List, generators)) $ region in
    let result =
      Premise_translate.translate_premise
        ctx env ~bound_vars (origin label) prem
    in
    (match result with
    | Premise_result.Blocked diagnostics
      when List.exists Diagnostics.is_fatal diagnostics -> ()
    | Blocked _ -> failwith (label ^ " blocked without a fatal diagnostic")
    | Deferred _ -> failwith (label ^ " remained deferred instead of blocked")
    | Complete _ -> failwith (label ^ " did not reject its unbound helper capture"));
    if Helper.materialize_static (Context.helpers ctx) <> [] then
      failwith (label ^ " left an orphan helper registration")
  in
  run
    "one-list-iter-transaction"
    [ id "renamed_iter_head", source "renamed_iter_source" ]
    [ "renamed_iter_source", "BOUND_SOURCE" ]
    [ "BOUND_SOURCE" ];
  run
    "zip-iter-transaction"
    [ id "renamed_iter_head", source "renamed_iter_source_left"
    ; id "renamed_iter_other", source "renamed_iter_source_right"
    ]
    [ "renamed_iter_source_left", "BOUND_SOURCE_LEFT"
    ; "renamed_iter_source_right", "BOUND_SOURCE_RIGHT"
    ]
    [ "BOUND_SOURCE_LEFT"; "BOUND_SOURCE_RIGHT" ];
  let rejected_count label generators source_bindings =
    let count_name = "renamed_rejected_count_" ^ label in
    let count_decl = DecD (id count_name, [], nat_typ, []) $ region in
    let source_index = Analysis.Source_index.of_script [ count_decl ] in
    let ctx = Context.create source_index (Builtin_registry.of_source_index source_index) in
    let env =
      source_bindings
      |> List.fold_left
           (fun env (source_id, term) ->
             Expr_env.add env source_id
               (binding term list_typ (sort "SpectecTerminals")))
           Expr_env.empty
    in
    let count = CallE (id count_name, []) $$ region % nat_typ in
    let body = IfPr (BoolE true $$ region % (BoolT $ region)) $ region in
    let prem = IterPr (body, (ListN (count, None), generators)) $ region in
    let result =
      Premise_translate.translate_premise
        ctx env
        ~bound_vars:(List.map snd source_bindings)
        (origin label) prem
    in
    (match result with
    | Premise_result.Blocked diagnostics
      when List.exists Diagnostics.is_fatal diagnostics -> ()
    | Blocked _ -> failwith (label ^ " blocked without a fatal diagnostic")
    | Deferred _ -> failwith (label ^ " remained deferred instead of blocked")
    | Complete _ ->
      failwith (label ^ " accepted a ListN count with no admissible term"));
    if Helper.materialize_static (Context.helpers ctx) <> [] then
      failwith (label ^ " registered a helper before rejecting its ListN count")
  in
  rejected_count
    "one-list-listn-count"
    [ id "renamed_count_head", source "renamed_count_source" ]
    [ "renamed_count_source", "BOUND_COUNT_SOURCE" ];
  rejected_count
    "zip-listn-count"
    [ id "renamed_count_left", source "renamed_count_source_left"
    ; id "renamed_count_right", source "renamed_count_source_right"
    ]
    [ "renamed_count_source_left", "BOUND_COUNT_LEFT"
    ; "renamed_count_source_right", "BOUND_COUNT_RIGHT"
    ]

let test_source_definition_atomicity () =
  let x = var "atomic_source_input" in
  let unsupported = NegPr (IfPr (BoolE true $$ region % (BoolT $ region)) $ region) $ region in
  let good_clause =
    DefD ([], [ ExpA x $ region ], x, []) $ region
  in
  let bad_clause =
    DefD ([], [ ExpA x $ region ], x, [ unsupported ]) $ region
  in
  let definition =
    DecD
      ( id "atomic_source_definition"
      , [ ExpP (id "atomic_source_input", nat_typ) $ region ]
      , nat_typ
      , [ good_clause; bad_clause ] )
    $ region
  in
  let relation_typ = TupT [ id "input", nat_typ; id "output", nat_typ ] $ region in
  let head = TupE [ x; x ] $$ region % relation_typ in
  let relation =
    RelD
      ( id "atomic_source_relation"
      , []
      , deterministic_mixop
      , relation_typ
      , [ RuleD (id "good", [], deterministic_mixop, head, []) $ region
        ; RuleD
            (id "bad", [], deterministic_mixop, head, [ unsupported ])
          $ region
        ] )
    $ region
  in
  List.iter
    (fun (label, def) ->
      let index = Analysis.Source_index.of_script [ def ] in
      let ctx = Context.create index (Builtin_registry.of_source_index index) in
      let translated = Def_translate.translate_script ctx [ def ] in
      if translated.statements <> [] then
        failwith (label ^ " retained successful siblings around a fatal sibling");
      if not (List.exists Diagnostics.is_fatal translated.diagnostics) then
        failwith (label ^ " atomicity fixture did not reach its fatal sibling");
      if Helper.materialize_static (Context.helpers ctx) <> [] then
        failwith (label ^ " committed helper state from a failed source definition"))
    [ "DecD", definition; "RelD", relation ]

let test_runtime_truth_source_boolean_observers () =
  (match boolean_worklist_result false with
  | Runtime_truth_worklist_materializer.Blocked_result diagnostics ->
    failwith
      ("total source Boolean RuleD was blocked: "
       ^ String.concat "; "
           (List.map (fun diagnostic -> diagnostic.Diagnostics.reason) diagnostics))
  | Complete_result complete ->
    let labels =
      Runtime_truth_worklist_materializer.complete_statements complete
      |> List.filter_map (fun statement ->
        match statement.Maude_ir.node with
        | Crl (Some label, _, _, _) -> Some label
        | Rl _ | Crl (None, _, _, _) | _ -> None)
    in
    if not (List.exists (fun label -> contains label "source-boolean") labels) then
      failwith "total source Boolean RuleD has no AST-derived false edge");
  match boolean_worklist_result true with
  | Complete_result _ ->
    failwith "partial non-equality IfPr materialized a public truth helper"
  | Blocked_result diagnostics ->
    if not
         (List.exists
            (fun diagnostic ->
              diagnostic.Diagnostics.constructor
              = "RuntimeTruthTotalEquality/CallE/clause-free-call"
              && Diagnostics.is_fatal diagnostic)
            diagnostics)
    then
      failwith
        "partial non-equality IfPr lost its premise-origin totality diagnostic"

let test_partial_numeric_operators_cannot_refute_equality () =
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let int_typ = NumT `IntT $ region in
  let int value = NumE (`Int (Z.of_int value)) $$ region % int_typ in
  let check name exp zero =
    match
      Runtime_truth_total_equality.false_conditions
        ctx Expr_env.empty (origin name) `EqOp exp zero
    with
    | Error blockers
      when List.exists (fun blocker ->
        blocker.Runtime_truth_total_equality.constructor
        = "RuntimeTruthTotalEquality/BinE/partial-operator") blockers -> ()
    | Error _ -> failwith (name ^ " reported an imprecise totality blocker")
    | Ok _ -> failwith (name ^ " was treated as total by inequality")
  in
  check "partial-pow"
    (BinE (`PowOp, `IntT, int 2, int (-1)) $$ region % int_typ) (int 0);
  check "partial-div"
    (BinE (`DivOp, `NatT, nat 2, nat 0) $$ region % nat_typ) (nat 0);
  check "partial-mod"
    (BinE (`ModOp, `NatT, nat 2, nat 0) $$ region % nat_typ) (nat 0);
  check "partial-nat-sub"
    (BinE (`SubOp, `NatT, nat 0, nat 1) $$ region % nat_typ) (nat 0)

let test_partial_destructor_domains_blocked () =
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let bool_typ = BoolT $ region in
  let tag = Xl.Atom.Atom "TAG" $$ region % Xl.Atom.info "missing" in
  let mixop = Xl.Mixop.Seq [ Xl.Mixop.Atom tag; Xl.Mixop.Arg () ] in
  let case_typ = VarT (id "missing", []) $ region in
  let case = CaseE (mixop, nat 0) $$ region % case_typ in
  let tuple_typ = TupT [ id "field", nat_typ ] $ region in
  let tuple = TupE [ nat 0 ] $$ region % tuple_typ in
  let checks =
    [ "CaseE", case
    ; "UncaseE", UncaseE (case, mixop) $$ region % nat_typ
    ; "ProjE", ProjE (tuple, 1) $$ region % nat_typ
    ; "DotE", DotE (case, tag) $$ region % nat_typ
    ]
  in
  List.iter (fun (name, exp) ->
    let condition = CmpE (`EqOp, `NatT, exp, nat 0) $$ region % bool_typ in
    match
      Runtime_truth_total_equality.source_boolean_alternatives
        ctx Expr_env.empty (origin ("partial-" ^ name)) condition
    with
    | Error (_ :: _) -> ()
    | Error [] -> failwith (name ^ " lost its domain blocker")
    | Ok _ -> failwith (name ^ " was total merely because its operands were total"))
    checks

let test_failed_proof_keeps_origin_and_lhs_scope () =
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let env =
    Expr_env.add Expr_env.empty "x"
      { term = Var "X"; sort = sort "Nat"; typ = nat_typ }
  in
  let quant = ExpP (id "y", nat_typ) $ region in
  let equality =
    CmpE (`EqOp, `NatT, var "y", var "x") $$ region % (BoolT $ region)
  in
  let result =
    Premise_translate.translate_premises
      ctx env ~bound_terms:[ Var "X" ] (origin "immutable-lhs")
      [ LetPr ([ quant ], var "y", var "x") $ region
      ; IfPr equality $ region
      ]
    |> complete_premise "immutable-lhs"
  in
  if Premise_result.lhs_bound_vars result <> [ "X" ] then
    failwith "earlier premise binder leaked into immutable lhs_bound_vars";
  let equality_conditions =
    match Premise_result.eq_conditions result with
    | _binding :: conditions -> conditions
    | [] -> failwith "immutable-lhs regression emitted no premise conditions"
  in
  let failures =
    Source_condition_certificate.blockers
      (Premise_result.source_condition_failures result) equality_conditions
  in
  (match failures with
  | failure :: _
    when failure.Source_condition_certificate.constructor <> ""
         && failure.reason <> ""
         && failure.source_echo <> None -> ()
  | _ -> failwith "failed totality proof lost origin/constructor/reason evidence");
  match
    Reld_enabledness_direct_complement
    .certified_sequential_complement_alternatives
      (Context.constructors ctx)
      ~origin:(origin "immutable-lhs")
      ~helper_name:"ImmutableLhs"
      ~condition_certificates:(Premise_result.source_condition_certificates result)
      ~condition_failures:(Premise_result.source_condition_failures result)
      [ Var "X" ] (Premise_result.eq_conditions result)
  with
  | Blocked (_ :: _) -> ()
  | Blocked [] -> failwith "immutable-lhs complement lost its blocker"
  | Complete _ -> failwith "earlier premise binder certified an Else complement"

let partial_hint name =
  let hint =
    { hintid = id "partial"; hintexp = El.Ast.BoolE true $ region }
  in
  HintD (DecH (id name, [ hint ]) $ region) $ region

let synchronized_definition ?(decreasing = true) name =
  let seq_typ = IterT (nat_typ, List) $ region in
  let seq_var name = VarE (id name) $$ region % seq_typ in
  let empty = ListE [] $$ region % seq_typ in
  let head name = var name in
  let tail name = seq_var name in
  let cons head tail = CatE (ListE [ head ] $$ region % seq_typ, tail) $$ region % seq_typ in
  let left = cons (head "left_head") (tail "left_tail") in
  let right = cons (head "right_head") (tail "right_tail") in
  let recursive_args =
    if decreasing then [ tail "left_tail"; tail "right_tail" ]
    else [ left; right ]
  in
  let recursive =
    CallE (id name, List.map (fun exp -> ExpA exp $ region) recursive_args)
    $$ region % nat_typ
  in
  let arg exp = ExpA exp $ region in
  let base = DefD ([], [ arg empty; arg empty ], nat 0, []) $ region in
  let step = DefD ([], [ arg left; arg right ], recursive, []) $ region in
  [ partial_hint name
  ; DecD
      (id name,
       [ ExpP (id "left", seq_typ) $ region; ExpP (id "right", seq_typ) $ region ],
       nat_typ, [ base; step ])
    $ region
  ]

let synchronized_call ctx name left right =
  let call =
    CallE (id name, [ ExpA left $ region; ExpA right $ region ])
    $$ region % nat_typ
  in
  Runtime_truth_total_equality.false_conditions
    ctx Expr_env.empty (origin name) `EqOp call (nat 1)

let list values =
  ListE (List.map nat values) $$ region % (IterT (nat_typ, List) $ region)

let test_synchronized_totality_domain () =
  let name = "renamed_zip_total" in
  let script = synchronized_definition name in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  (match synchronized_call ctx name (list [ 1; 2 ]) (list [ 3; 4 ]) with
  | Ok _ -> ()
  | Error blockers ->
    failwith
      ("equal-length synchronized call was not certified: "
       ^ String.concat "; "
           (List.map (fun blocker ->
              blocker.Runtime_truth_total_equality.reason) blockers)));
  match synchronized_call ctx name (list [ 1 ]) (list [ 2; 3 ]) with
  | Error blockers
    when List.exists (fun blocker ->
      blocker.Runtime_truth_total_equality.constructor
      = "RuntimeTruthTotalEquality/CallE/open-clause-domain") blockers -> ()
  | Error _ -> failwith "unequal synchronized domains lost their blocker"
  | Ok _ -> failwith "unequal synchronized sequence domains were certified"

let test_nondecreasing_recursion_rejected () =
  let name = "renamed_zip_nondecreasing" in
  let script = synchronized_definition ~decreasing:false name in
  let index = Analysis.Source_index.of_script script in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  match synchronized_call ctx name (list [ 1 ]) (list [ 2 ]) with
  | Error blockers
    when List.exists (fun blocker ->
      blocker.Runtime_truth_total_equality.constructor
      = "RuntimeTruthTotalEquality/CallE/recursive-call") blockers -> ()
  | Error _ -> failwith "non-decreasing recursion lost its exact blocker"
  | Ok _ -> failwith "non-decreasing recursive call was certified total"

let guarded_partition_definition ?(with_guard = true) name =
  let x = var "partition_input" in
  let arg = ExpA x $ region in
  let otherwise = DefD ([], [ arg ], nat 1, [ ElsePr $ region ]) $ region in
  let clauses =
    if not with_guard then [ otherwise ] else
      let guard = CmpE (`EqOp, `NatT, x, x) $$ region % (BoolT $ region) in
      [ DefD ([], [ arg ], nat 0, [ IfPr guard $ region ]) $ region
      ; otherwise
      ]
  in
  DecD (id name, [ ExpP (id "partition_input", nat_typ) $ region ], nat_typ, clauses)
  $ region

let partition_call ctx name =
  let call = CallE (id name, [ ExpA (nat 0) $ region ]) $$ region % nat_typ in
  Runtime_truth_total_equality.false_conditions
    ctx Expr_env.empty (origin name) `EqOp call (nat 2)

let test_guard_else_partition_certificate () =
  let complete_name = "renamed_guard_partition" in
  let complete = guarded_partition_definition complete_name in
  let index = Analysis.Source_index.of_script [ complete ] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  (match partition_call ctx complete_name with
  | Ok _ -> ()
  | Error _ -> failwith "guard/Else source partition was not certified");
  let lone_name = "renamed_lone_else" in
  let lone = guarded_partition_definition ~with_guard:false lone_name in
  let index = Analysis.Source_index.of_script [ lone ] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  match partition_call ctx lone_name with
  | Error blockers
    when List.exists (fun blocker ->
      blocker.Runtime_truth_total_equality.constructor
      = "RuntimeTruthTotalEquality/CallE/open-clause-domain") blockers -> ()
  | Error _ -> failwith "lone Else partition lost its exact blocker"
  | Ok _ -> failwith "lone ElsePr was treated as a complete total partition"

let test_helper_closure_fixed_point () =
  let next = ref 0 in
  let pending () =
    if !next > 64 then []
    else [ { Helper_closure.key = "dependency-" ^ string_of_int !next; value = !next } ]
  in
  let closure =
    Helper_closure.run ~pending ~materialize:(fun value ->
      if value = !next then (incr next; Some value) else None)
  in
  if closure.stalled <> [] || List.length closure.completed <> 65 then
    failwith "helper closure retained an arbitrary round cap";
  let pending () =
    [ { Helper_closure.key = "cycle-a"; value = "a" }
    ; { Helper_closure.key = "cycle-b"; value = "b" }
    ]
  in
  let closure = Helper_closure.run ~pending ~materialize:(fun _ -> None) in
  if List.length closure.stalled <> 2 then
    failwith "non-progressing helper requests were not reported individually"

let test_atomic_blocked_helper_emission () =
  let item provenance node =
    Maude_ir.generated
      ~provenance ~origin:(origin "atomic-helper") node
  in
  let terminal = sort "SpectecTerminal" in
  let statements =
    [ item (Helper "Dependent")
        (op "dependentHelper" [] terminal)
    ; item (Helper "Dependent")
        (eq
           (App ("dependentHelper", []))
           (App ("blockedWorklist", [])))
    ; item Source (op "sourceCaller" [] terminal)
    ; item Source
        (eq (App ("sourceCaller", [])) (App ("dependentHelper", [])))
    ; item Source (op "unrelated" [] terminal)
    ; item Source (eq (App ("unrelated", [])) (Const "safe"))
    ; item Source (op "directBlockedCaller" [] terminal)
    ; item Source
        (eq (App ("directBlockedCaller", [])) (App ("blockedWorklist", [])))
    ]
  in
  let blocked_declarations =
    [ item (Helper "Blocked") (op "blockedWorklist" [] terminal) ]
  in
  let result =
    Generated_reachability.retain
      ~blocked_declarations statements
  in
  let retained = result.statements in
  if
    List.exists
      (fun statement ->
        match statement.provenance with
        | Helper "Dependent" -> true
        | Prelude | Source | Helper _ -> false)
      retained
  then
    failwith "blocked dependency retained a partial helper surface";
  if not
    (List.exists
      (fun statement ->
        match statement.node with
        | Eq (_, App ("dependentHelper", _), _)
        | Eq (App ("dependentHelper", _), _, _)
        | Ceq (_, App ("dependentHelper", _), _, _)
        | Ceq (App ("dependentHelper", _), _, _, _) -> true
        | _ -> false)
      retained)
  then
    failwith "reachability pruning deleted a source statement";
  if not
       (List.exists
          (fun violation ->
            violation.Generated_reachability.constructor
            = "GeneratedReachability/source-depends-on-blocked-helper"
            && contains violation.reason "blockedWorklist/0")
          result.violations)
  then
    failwith
      "direct source dependency on an absent blocked helper lost its fatal invariant evidence";
  if
    not
      (List.exists
         (fun statement ->
           match statement.node with
           | Eq (App ("unrelated", []), Const "safe", []) -> true
           | _ -> false)
         retained)
  then
    failwith "atomic helper pruning removed an unrelated source equation"

let test_generated_helper_reachability () =
  let item provenance node =
    Maude_ir.generated
      ~provenance ~origin:(origin "helper-reachability") node
  in
  let terminal = sort "SpectecTerminal" in
  let helper owner name dependency =
    [ item (Helper owner) (op name [] terminal)
    ; item (Helper owner)
        (eq (App (name, [])) dependency)
    ]
  in
  let statements =
    [ item Source (op "retainedSourceRoot" [] terminal)
    ; item Source
        (eq (App ("retainedSourceRoot", [])) (App ("reachableA", [])))
    ]
    @ helper "ReachableA" "reachableA" (App ("reachableB", []))
    @ helper "ReachableB" "reachableB" (Const "safe")
    @ helper "OrphanC" "orphanC" (Const "safe")
  in
  let retained =
    Driver.retain_atomic_statements ~blocked_declarations:[] statements
  in
  let owners =
    retained
    |> List.filter_map (fun statement ->
      match statement.provenance with
      | Helper owner -> Some owner
      | Prelude | Source -> None)
    |> List.sort_uniq String.compare
  in
  if owners <> [ "ReachableA"; "ReachableB" ] then
    failwith
      ("helper reachability did not retain exactly the source-rooted closure: "
       ^ String.concat ", " owners)

let test_generated_reachability_typed_dependencies () =
  let item provenance node =
    Maude_ir.generated
      ~provenance ~origin:(origin "typed-helper-reachability") node
  in
  let terminal = sort "SpectecTerminal" in
  let nat = sort "Nat" in
  let helper_sort = sort "ReachabilityHelperSort" in
  let blocked_sort = sort "BlockedGeneratedSort" in
  let statements =
    [ item (Helper "SortOwner") (sort_decl helper_sort)
    ; item Source (op "sourceSortRoot" [] helper_sort)
    ; item (Helper "OverTerminal")
        (op "overloadedReachability" [ sort_ref terminal ] terminal)
    ; item (Helper "OverNat")
        (op "overloadedReachability" [ sort_ref nat ] terminal)
    ; item Source (op "sourceOverloadRoot" [] terminal)
    ; item Source
        (eq (App ("sourceOverloadRoot", []))
           (App ("overloadedReachability", [ Const "safe" ])))
    ; item (Helper "ConditionOnly") (op "conditionOnlyHelper" [] terminal)
    ; item Source (op "sourceConditionRoot" [] terminal)
    ; item Source
        (ceq (App ("sourceConditionRoot", [])) (Const "safe")
           [ BoolCond (App ("conditionOnlyHelper", [])) ])
    ; item Source (op "reservedSourceName" [] terminal)
    ; item (Helper "Collision") (op "reservedSourceName" [ sort_ref nat ] terminal)
    ; item (Helper "BlockedTail") (op "blockedTail" [] terminal)
    ; item (Helper "BlockedTail")
        (eq (App ("blockedTail", [])) (App ("blockedWorklist", [])))
    ; item (Helper "BlockedHead") (op "blockedHead" [] terminal)
    ; item (Helper "BlockedHead")
        (eq (App ("blockedHead", [])) (App ("blockedTail", [])))
    ; item Source (op "blockedSourceRoot" [] terminal)
    ; item Source
        (eq (App ("blockedSourceRoot", [])) (App ("blockedHead", [])))
    ; item (Helper "BlockedSortTail")
        (op "blockedSortTail" [] blocked_sort)
    ; item (Helper "BlockedSortHead")
        (op "blockedSortHead" [ sort_ref blocked_sort ] terminal)
    ; item Source (op "blockedSortSource" [] blocked_sort)
    ]
  in
  let result =
    let blocked_declarations =
      [ item (Helper "Blocked") (op "blockedWorklist" [] terminal)
      ; item (Helper "BlockedSort") (sort_decl blocked_sort)
      ]
    in
    Generated_reachability.retain
      ~blocked_declarations statements
  in
  let owners =
    result.statements
    |> List.filter_map (fun statement ->
      match statement.provenance with
      | Helper owner -> Some owner
      | Prelude | Source -> None)
    |> List.sort_uniq String.compare
  in
  List.iter
    (fun owner ->
      if not (List.mem owner owners) then
        failwith ("typed helper dependency was pruned: " ^ owner))
    [ "SortOwner"; "OverTerminal"; "OverNat"; "ConditionOnly" ];
  List.iter
    (fun owner ->
      if List.mem owner owners then
        failwith ("blocked transitive helper chain was retained: " ^ owner))
    [ "BlockedHead"; "BlockedTail"; "BlockedSortHead"; "BlockedSortTail" ];
  if
    not
      (List.exists (fun statement ->
         match statement.node with
         | Eq (App ("blockedSourceRoot", []), App ("blockedHead", []), []) -> true
         | _ -> false) result.statements)
  then failwith "blocked helper pruning deleted its source root";
  if not
       (List.exists (fun statement ->
          match statement.node with
          | OpDecl declaration -> declaration.name = "blockedSortSource"
          | _ -> false) result.statements)
  then failwith "blocked generated sort pruning deleted its source declaration";
  if not
       (List.exists (fun violation ->
          violation.Generated_reachability.constructor
          = "GeneratedReachability/source-depends-on-blocked-helper"
          && contains violation.reason "BlockedGeneratedSort")
          result.violations)
  then failwith "blocked generated sort lost its source dependency violation";
  List.iter
    (fun constructor ->
      if not (List.exists (fun violation ->
          violation.Generated_reachability.constructor = constructor)
          result.violations)
      then failwith ("generated reachability lost violation " ^ constructor))
    [ "GeneratedReachability/helper-namespace-collision"
    ; "GeneratedReachability/source-depends-on-blocked-helper"
    ]

let test_structural_match_pattern_certificate () =
  let unknown = App ("renamedUnknownPattern", [ Var "X" ]) in
  List.iter
    (fun name ->
      if Condition_closure.is_match_pattern (App (name, [ Var "X" ])) then
        failwith ("operator-name heuristic still certifies matching: " ^ name))
    [ "renamedUnknownPattern"; "defAlpha"; "helperAlpha"; "proj.alpha"; "rec-alpha" ];
  let source_index = Analysis.Source_index.of_script [] in
  let ctx = Context.create source_index (Builtin_registry.of_source_index source_index) in
  let before = Condition_closure.source_constructor_certificate ctx in
  if not (Condition_pattern_certificate.admits before "item" 2)
     || not (Condition_pattern_certificate.admits before "{_}" 1)
     || Condition_pattern_certificate.admits before "item" 1
  then failwith "record constructor descriptors lost exact prelude arity";
  Constructor_registry.register (Context.constructors ctx)
    { source_category = "renamed-category"
    ; declaring_category = "renamed-category"
    ; static_args_key = None
    ; mixop
    ; arity = 1
    ; constructor_op = "renamedUnknownPattern"
    ; projection_ops = []
    ; payload_labels = [ Constructor_registry.Structural_payload ]
    ; payload_witnesses = [ Var "X" ]
    ; payload_sorts = [ sort "Nat" ]
    ; origin = origin "pattern-certificate"
    ; enclosing = [ "renamed-category" ]
    ; status = Constructor_registry.Emitted
    ; construction_domain = Constructor_registry.Total_constructor
    };
  if Condition_pattern_certificate.is_pattern before unknown then
    failwith "constructor snapshot changed after registry mutation";
  let after = Condition_closure.source_constructor_certificate ctx in
  if not
       (Condition_closure.is_match_pattern
          ~constructor_op:after
          unknown)
  then failwith "source constructor registry certificate did not justify matching";
  if Condition_pattern_certificate.admits after "renamedUnknownPattern" 2 then
    failwith "constructor certificate ignored exact arity";
  let generated name args =
    Maude_ir.generated
      ~provenance:Source
      ~origin:(origin ("pattern-" ^ name))
      (op name args (sort "SpectecTerminal") ~attrs:[ Ctor ])
  in
  let left =
    Condition_pattern_certificate.generated
      [ generated "leftPattern" [ sort_ref (sort "Nat") ] ]
  in
  let right =
    Condition_pattern_certificate.generated
      [ generated "rightPattern" [ sort_ref (sort "String") ] ]
  in
  let combined = Condition_pattern_certificate.union left right in
  if not (Condition_pattern_certificate.admits combined "leftPattern" 1)
     || not (Condition_pattern_certificate.admits combined "rightPattern" 1)
  then failwith "pattern certificate union discarded a signature";
  let ambiguous =
    Condition_pattern_certificate.generated
      [ generated "overloadedPattern" [ sort_ref (sort "Nat") ]
      ; generated "overloadedPattern" [ sort_ref (sort "String") ]
      ]
  in
  if Condition_pattern_certificate.admits ambiguous "overloadedPattern" 1 then
    failwith "ambiguous pattern overload was accepted";
  let ambient =
    Condition_pattern_certificate.generated
      [ generated "ambientPattern" [ sort_ref (sort "Nat") ] ]
  in
  let statement =
    Maude_ir.generated
      ~provenance:Source
      ~origin:(origin "ambient-singleton")
      (crl
         (Var "S")
         (Var "X")
         [ EqCondition
             (MatchCond (App ("ambientPattern", [ Var "X" ]), Var "S"))
         ])
  in
  let _, without_ambient = Maude_registry.build [ statement ] in
  let _, with_ambient =
    Maude_registry.build ~ambient_patterns:ambient [ statement ]
  in
  if without_ambient = [] || with_ambient <> [] then
    failwith "singleton Maude validation did not preserve its ambient pattern certificate";
  let reducible_statements =
    [ generated "reducibleCtor" [ sort_ref (sort "Nat") ]
    ; Maude_ir.generated ~provenance:Source ~origin:(origin "reducible-ctor")
        (eq (App ("reducibleCtor", [ Var "X" ])) (Var "X"))
    ; generated "outerCtor" [ sort_ref (sort "SpectecTerminal") ]
    ; generated "knownConstant" []
    ]
  in
  let reducible = Condition_pattern_certificate.generated reducible_statements in
  if Condition_pattern_certificate.is_pattern reducible
       (App ("reducibleCtor", [ Var "X" ]))
     || Condition_pattern_certificate.is_pattern reducible
          (App ("outerCtor", [ App ("reducibleCtor", [ Var "X" ]) ]))
  then failwith "equation-reducible [ctor] root was accepted as an E(M)-pattern";
  if not (Condition_pattern_certificate.is_pattern reducible (Const "knownConstant"))
     || not (Condition_pattern_certificate.is_pattern reducible (Qid "knownConstant"))
     || Condition_pattern_certificate.is_pattern reducible (Const "unknownConstant")
     || not (Condition_pattern_certificate.is_pattern reducible (Qid "unknownQid"))
  then failwith "Const declarations and quoted Qid atoms were not distinguished";
  let associative =
    Condition_pattern_certificate.generated
      [ Maude_ir.generated ~provenance:Source ~origin:(origin "assoc-ctor")
          (op "assocCtor" [ sort_ref (sort "Nat"); sort_ref (sort "Nat") ]
             (sort "Nat") ~attrs:[ Ctor; Assoc ])
      ]
  in
  if Condition_pattern_certificate.is_pattern associative
       (App ("assocCtor", [ Var "X"; Var "Y" ]))
  then failwith "associative [ctor] was certified by syntactic non-overlap";
  let sequence_certificate =
    Condition_pattern_certificate.generated
      (Prelude.statements
       @ [ Maude_ir.generated ~provenance:Source
             ~origin:(origin "sequence-singleton-left")
             (Maude_ir.var "SINGLETON-LEFT"
                (sort_ref (sort "SpectecTerminal")))
         ; Maude_ir.generated ~provenance:Source
             ~origin:(origin "sequence-singleton-right")
             (Maude_ir.var "SINGLETON-RIGHT"
                (sort_ref (sort "SpectecTerminal")))
         ; Maude_ir.generated ~provenance:Source
             ~origin:(origin "sequence-open")
             (Maude_ir.var "OPEN-SEQUENCE"
                (sort_ref (sort "SpectecTerminals")))
         ])
  in
  let fixed_sequence =
    App
      ( "tuple"
      , [ App ("_ _", [ Var "SINGLETON-LEFT"; Var "SINGLETON-RIGHT" ]) ] )
  in
  let open_sequence =
    App
      ( "tuple"
      , [ App ("_ _", [ Var "OPEN-SEQUENCE"; Var "SINGLETON-RIGHT" ]) ] )
  in
  if not (Condition_pattern_certificate.is_pattern sequence_certificate fixed_sequence)
     || Condition_pattern_certificate.is_pattern sequence_certificate open_sequence
  then
    failwith
      "explicit prelude sequence contract did not distinguish fixed singleton and open associative patterns";
  if not
       (Condition_pattern_certificate.is_pattern
          Condition_pattern_certificate.imported (Const "true"))
     || not
          (Condition_pattern_certificate.is_pattern
             Condition_pattern_certificate.imported
             (App ("s_", [ Const "0" ])))
     || not
          (Condition_pattern_certificate.is_pattern
             Condition_pattern_certificate.imported (Const "eps"))
  then failwith "explicit imported primitive pattern contracts were not preserved";
  let rewrite =
    Maude_ir.generated ~provenance:Source ~origin:(origin "bound-reducible-rhs")
      (crl (App ("root", [ Var "X" ])) (Var "X")
         [ RewriteCond
             (App ("search", [ Var "X" ]),
              App ("reducibleCtor", [ Var "X" ])) ])
  in
  let _, violations =
    Maude_registry.build (reducible_statements @ [ rewrite ])
  in
  if not (List.exists (fun violation ->
      violation.Maude_registry.constructor
      = "MaudeRegistry/crl-condition-admissibility") violations)
  then failwith "bound-variable rewrite RHS bypassed E(M)-pattern validation"

let ingress_slice_script stem ~source_complete ~escape_to_rhs ~escape_to_rest =
  let name suffix = stem ^ "_" ^ suffix in
  let tuple_typ names =
    TupT (List.map (fun name -> id name, nat_typ) names) $ region
  in
  let tuple exps typ = TupE exps $$ region % typ in
  let output_typ = tuple_typ [ "witness"; "unused" ] in
  let producer_typ = TupT [ id "input", nat_typ; id "output", output_typ ] $ region in
  let consumer_typ = tuple_typ [ "input"; "item"; "witness" ] in
  let input = var (name "input") in
  let witness = var (name "witness") in
  let unused = var (name "unused") in
  let output = tuple [ witness; unused ] output_typ in
  let producer_rules =
    if source_complete then
      [ RuleD
          (id "_", [], deterministic_mixop,
           tuple [ input; output ] producer_typ, [])
        $ region
      ]
    else []
  in
  let consumer_rules =
    if source_complete then
      [ RuleD
          (id "_", [], predicate_mixop,
           tuple [ input; witness; witness ] consumer_typ, [])
        $ region
      ]
    else []
  in
  let producer =
    RelD
      ( id (name "producer")
      , []
      , deterministic_mixop
      , producer_typ
      , producer_rules )
    $ region
  in
  let consumer =
    RelD
      (id (name "consumer"), [], predicate_mixop, consumer_typ, consumer_rules)
    $ region
  in
  let execution_typ = tuple_typ [ "before"; "after" ] in
  let execution =
    RelD
      (id (name "execution"), [], execution_mixop, execution_typ, [])
    $ region
  in
  let item = id (name "item") in
  let producer_premise =
    RulePr
      ( id (name "producer")
      , []
      , deterministic_mixop
      , tuple [ input; output ] producer_typ )
    $ region
  in
  let consumer_body =
    RulePr
      ( id (name "consumer")
      , []
      , predicate_mixop
      , tuple [ input; VarE item $$ region % nat_typ; witness ] consumer_typ )
    $ region
  in
  let consumer_premise =
    IterPr (consumer_body, (List, [ item, input ])) $ region
  in
  let rest =
    if escape_to_rest then
      [ IfPr
          (CmpE (`EqOp, `NatT, witness, witness)
           $$ region % (BoolT $ region))
        $ region
      ]
    else []
  in
  let rhs = if escape_to_rhs then witness else input in
  let clause =
    DefD
      ( []
      , [ ExpA input $ region ]
      , rhs
      , producer_premise :: consumer_premise :: rest )
    $ region
  in
  let entry =
    DecD
      ( id (name "entry")
      , [ ExpP (id (name "input"), nat_typ) $ region ]
      , nat_typ
      , [ clause ] )
    $ region
  in
  [ producer; consumer; execution; entry ], clause

let ingress_spec index stem =
  let spec =
    { Runtime_ingress_contract.capability = Invocation
    ; origin = "test:" ^ stem
    ; definition_id = stem ^ "_entry"
    ; clause_index = 0
    ; producer_premise_index = 0
    ; consumer_premise_index = 1
    ; producer_relation_id = stem ^ "_producer"
    ; consumer_relation_id = stem ^ "_consumer"
    ; producer_output_indices = [ 1 ]
    ; source_digest = ""
    ; trusted_formula_digest =
        Runtime_ingress_contract.expected_formula_digest Invocation
    }
  in
  let source_digest =
    match Runtime_ingress_contract.expected_source_digest index spec with
    | Ok digest -> digest
    | Error error -> failwith error
  in
  { spec with source_digest }

let ingress_contract index stem =
  Runtime_ingress_contract.resolve
    index
    [ ingress_spec index stem ]
  |> function
  | Ok contract -> contract
  | Error errors ->
    failwith
      (String.concat "; "
         (List.map Runtime_ingress_contract.error_reason errors))

let test_runtime_ingress_contract_validation () =
  let script, _ =
    ingress_slice_script "contract_validation" ~source_complete:true
      ~escape_to_rhs:false ~escape_to_rest:false
  in
  let index = Analysis.Source_index.of_script script in
  let spec = ingress_spec index "contract_validation" in
  let expect_error ?(origins = []) fragment specs =
    match Runtime_ingress_contract.resolve index specs with
    | Ok _ -> failwith ("ingress contract accepted " ^ fragment)
    | Error errors
      when List.exists
             (fun error ->
               contains (Runtime_ingress_contract.error_reason error) fragment
               && List.for_all
                    (fun origin ->
                      let current =
                        Runtime_ingress_contract.error_provenance error
                      in
                      let previous =
                        Runtime_ingress_contract.error_previous_provenance error
                      in
                      String.equal current.origin origin
                      || Option.fold ~none:false
                           ~some:(fun provenance ->
                             String.equal
                               (provenance
                                 : Runtime_ingress_contract.provenance).origin
                               origin)
                           previous)
                    origins)
             errors -> ()
    | Error errors ->
      failwith
        ("ingress contract lost blocker `" ^ fragment ^ "`: "
         ^ String.concat "; "
             (List.map Runtime_ingress_contract.error_reason errors))
  in
  expect_error "has no zero-based clause index"
    [ { spec with clause_index = 9 } ];
  expect_error "stale ingress source digest"
    [ { spec with source_digest = "stale" } ];
  expect_error "stale ingress trusted-formula digest"
    [ { spec with trusted_formula_digest = "stale" } ];
  let conflicting =
    let changed = { spec with producer_output_indices = [] } in
    let source_digest =
      match Runtime_ingress_contract.expected_source_digest index changed with
      | Ok digest -> digest
      | Error error -> failwith error
    in
    { changed with source_digest }
  in
  let conflicting =
    { conflicting with origin = "test:contract_validation:conflicting" }
  in
  expect_error
    ~origins:[ spec.origin; conflicting.origin ]
    "duplicate runtime-ingress attestation"
    [ spec; conflicting ];
  let duplicate =
    { spec with origin = "test:contract_validation:duplicate" }
  in
  expect_error
    ~origins:[ spec.origin; duplicate.origin ]
    "duplicate runtime-ingress attestation"
    [ spec; duplicate ];
  let stale = { spec with source_digest = "stale" } in
  let stale_duplicate =
    { stale with origin = "test:contract_validation:stale-duplicate" }
  in
  expect_error
    ~origins:[ stale.origin; stale_duplicate.origin ]
    "duplicate runtime-ingress attestation"
    [ stale; stale_duplicate ];
  let duplicate_result =
    Driver.translate ~runtime_ingress_specs:[ spec; duplicate ] script
  in
  if not
       (List.exists
          (fun diagnostic ->
            diagnostic.Diagnostics.category = Unsupported
            && diagnostic.severity = Fatal
            && diagnostic.constructor = "RuntimeIngressContract/resolve"
            && contains diagnostic.reason spec.origin
            && contains diagnostic.reason duplicate.origin
            && Option.fold ~none:false
                 ~some:(fun source ->
                   contains source "definition=contract_validation_entry#")
                 diagnostic.source_echo)
          duplicate_result.diagnostics)
  then
    failwith
      "duplicate ingress key did not become a structured fatal Unsupported with both contract origins";
  let contract =
    match Runtime_ingress_contract.resolve index [ spec ] with
    | Ok contract -> contract
    | Error errors ->
      failwith
        (String.concat "; "
           (List.map Runtime_ingress_contract.error_reason errors))
  in
  (match Runtime_ingress_contract.attestations contract with
  | [ attestation ]
    when Runtime_ingress_contract.attestation_origin attestation = spec.origin ->
    let ctx =
      Context.create ~runtime_ingress_contract:contract index
        (Builtin_registry.of_source_index index)
    in
    if Context.unused_runtime_ingress_attestations ctx = [] then
      failwith "fresh ingress attestation was not tracked as unused";
    let stage = Context.begin_stage ctx in
    Context.use_runtime_ingress_attestation (Context.staged stage) attestation;
    if Context.unused_runtime_ingress_attestations ctx = [] then
      failwith "rolled-back ingress use leaked into its target Context";
    Context.commit_stage stage;
    if Context.unused_runtime_ingress_attestations ctx <> [] then
      failwith "committed ingress use remained incorrectly marked unused"
  | _ -> failwith "single exact ingress attestation lost its provenance")

let test_runtime_ingress_slice_certificate () =
  let script, clause =
    ingress_slice_script "missing_contract" ~source_complete:false
      ~escape_to_rhs:false ~escape_to_rest:false
  in
  let index = Analysis.Source_index.of_script script in
  let no_contract_ctx = Context.create index (Builtin_registry.of_source_index index) in
  (match clause.it with
  | DefD (_, args, rhs, prems) ->
    let discharge =
      Runtime_ingress_slice_certificate.certify
        no_contract_ctx ~definition_id:"missing_contract_entry" ~clause_index:0
        ~lhs_args:args ~rhs prems
    in
    if discharge.certificates <> [] || discharge.blockers = [] then
      failwith "an empty ingress contract admitted an arbitrary validation slice");
  let check stem =
    let script, clause =
      ingress_slice_script stem ~source_complete:true
        ~escape_to_rhs:false ~escape_to_rest:false
    in
    let index = Analysis.Source_index.of_script script in
    let ctx =
      Context.create
        ~runtime_ingress_contract:(ingress_contract index stem)
        index (Builtin_registry.of_source_index index)
    in
    match clause.it with
    | DefD (_, args, rhs, prems) ->
      let discharge =
        Runtime_ingress_slice_certificate.certify
          ctx ~definition_id:(stem ^ "_entry") ~clause_index:0
          ~lhs_args:args ~rhs prems
      in
      if discharge.retained <> []
         || List.length discharge.certificates <> 1
         || discharge.blockers <> []
      then
        failwith (stem ^ " did not discharge exactly one contiguous ingress slice")
  in
  check "renamed_ingress";
  check "alpha_ingress";
  let script, clause =
    ingress_slice_script "nonprefix_ingress"
      ~source_complete:true
      ~escape_to_rhs:false ~escape_to_rest:false
  in
  let index = Analysis.Source_index.of_script script in
  let ctx =
    Context.create
      ~runtime_ingress_contract:(ingress_contract index "nonprefix_ingress")
      index (Builtin_registry.of_source_index index)
  in
  (match clause.it with
  | DefD (_, args, rhs, prems) ->
    let leading = IfPr (BoolE true $$ region % (BoolT $ region)) $ region in
    let discharge =
      Runtime_ingress_slice_certificate.certify
        ctx ~definition_id:"nonprefix_ingress_entry" ~clause_index:0
        ~lhs_args:args ~rhs
        (leading :: prems)
    in
    if discharge.certificates <> [] || discharge.blockers <> [] then
      failwith "a later ingress-like pair was discharged outside the validation prefix");
  List.iter
    (fun (label, escape_to_rhs, escape_to_rest) ->
      let script, clause =
        ingress_slice_script label ~source_complete:true
          ~escape_to_rhs ~escape_to_rest
      in
      let index = Analysis.Source_index.of_script script in
      let ctx =
        Context.create
          ~runtime_ingress_contract:(ingress_contract index label)
          index (Builtin_registry.of_source_index index)
      in
      match clause.it with
      | DefD (_, args, rhs, prems) ->
        let discharge =
          Runtime_ingress_slice_certificate.certify
            ctx ~definition_id:(label ^ "_entry") ~clause_index:0
            ~lhs_args:args ~rhs prems
        in
        if discharge.certificates <> [] then
          failwith (label ^ " discharged an escaping validation witness");
        if
          not
            (List.exists
               (fun blocker ->
                 contains
                   (Runtime_ingress_slice_certificate.blocker_reason blocker)
                   "escapes"
                 && Runtime_ingress_slice_certificate.blocker_suggestion blocker
                    <> ""
                 && Runtime_ingress_slice_certificate.blocker_source_echo blocker
                    <> "")
               discharge.blockers)
        then
          failwith (label ^ " lost its typed non-escape blocker"))
    [ "rhs_escape", true, false; "rest_escape", false, true ]

let test_pure_decd_rejects_rule_conditions () =
  let list_typ = IterT (nat_typ, List) $ region in
  let member = typed_var nat_typ "pure_member" in
  let members = typed_var list_typ "pure_members" in
  let premise =
    IfPr (MemE (member, members) $$ region % (BoolT $ region)) $ region
  in
  let parameter = ExpP (id "pure_members", list_typ) $ region in
  let clause =
    DefD
      ( [ ExpP (id "pure_member", nat_typ) $ region; parameter ]
      , [ ExpA members $ region ]
      , member
      , [ premise ] )
    $ region
  in
  let definition_id = id "pure_rule_condition_guard" in
  let definition =
    DecD (definition_id, [ parameter ], nat_typ, [ clause ]) $ region
  in
  (* Deliberately use a context whose graph does not promote this synthetic
     definition: this exercises the pure-DecD emission invariant directly. *)
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let output = Def_translate.translate_script ctx [ definition ] in
  if not
       (List.exists (fun diagnostic ->
          diagnostic.Diagnostics.constructor = "DecD/pure/rule-condition"
          && Diagnostics.is_fatal diagnostic) output.diagnostics)
  then failwith "pure DecD silently accepted a premise RewriteCond";
  let op_name = Naming.definition_op definition_id in
  if List.exists (fun statement ->
       match statement.node with
       | Eq (App (name, _), _, _) | Ceq (App (name, _), _, _, _)
         when name = op_name -> true
       | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
       | Rl _ | Crl _ | Eq _ | Ceq _ -> false) output.statements
  then failwith "pure DecD emitted eq/ceq after observing a RewriteCond"

let test_equality_binding_orientation () =
  let certificate =
    Condition_pattern_certificate.generated Prelude.statements
  in
  let target = Var "EQUALITY-TARGET" in
  let field = Var "EQUALITY-FIELD" in
  let record value =
    App ("{_}", [ App ("item", [ Qid "FIELD"; value ]) ])
  in
  let condition = EqCond (target, record field) in
  let bound =
    Condition_closure.conditions_bound_vars
      ~constructor_op:certificate [ "EQUALITY-FIELD" ] [ condition ]
  in
  if not (List.mem "EQUALITY-TARGET" bound) then
    failwith "ready EqCond did not expose its certified pattern binding";
  (match
     Condition_closure.conditions_admissible_bound
       ~constructor_op:certificate [ "EQUALITY-FIELD" ] [ condition ]
   with
  | Some bound when List.mem "EQUALITY-TARGET" bound -> ()
  | _ -> failwith "early EqCond admissibility disagreed with final orientation");
  (match
     Condition_closure.normalize_binding_conditions
       ~constructor_op:certificate [ field ] [ condition ]
   with
  | [ MatchCond (pattern, subject) ]
    when pattern = target && subject = record field -> ()
  | _ -> failwith "ready EqCond did not normalize to the shared MatchCond orientation");
  let blocked = EqCond (target, record (Var "EQUALITY-MISSING")) in
  let bound =
    Condition_closure.conditions_bound_vars
      ~constructor_op:certificate [ "EQUALITY-FIELD" ] [ blocked ]
  in
  if List.mem "EQUALITY-TARGET" bound then
    failwith "EqCond bound its pattern while the opposite side remained open";
  (match
     Condition_closure.conditions_admissible_bound
       ~constructor_op:certificate [ "EQUALITY-FIELD" ] [ blocked ]
   with
  | None -> ()
  | Some _ -> failwith "early EqCond admissibility accepted an open opposite side");
  match
    Condition_closure.normalize_binding_conditions
      ~constructor_op:certificate [ field ] [ blocked ]
  with
  | [ EqCond _ ] -> ()
  | _ -> failwith "unready EqCond was incorrectly oriented as a binding"

let test_equality_external_closure_orientation () =
  let certificate =
    Condition_pattern_certificate.generated Prelude.statements
  in
  let target = Var "EXTERNAL-EQUALITY-TARGET" in
  let field = Var "EXTERNAL-EQUALITY-FIELD" in
  let record value =
    App ("{_}", [ App ("item", [ Qid "FIELD"; value ]) ])
  in
  let condition = EqCond (target, record field) in
  let conditions = [ condition; BoolCond (App ("observe", [ target ])) ] in
  if
    Condition_closure.external_vars_of_conditions
      ~constructor_op:certificate [ "EXTERNAL-EQUALITY-FIELD" ] conditions
    <> []
  then failwith "EqCond pattern variables leaked into equation external closure";
  if
    Condition_closure.external_vars_of_term_after_conditions
      ~constructor_op:certificate
      [ "EXTERNAL-EQUALITY-FIELD" ] target [ condition ]
    <> []
  then failwith "EqCond binding did not close the following term";
  if
    Condition_closure.external_vars_of_rule_conditions
      ~constructor_op:certificate
      [ "EXTERNAL-EQUALITY-FIELD" ]
      [ EqCondition condition; EqCondition (BoolCond (App ("observe", [ target ]))) ]
    <> []
  then failwith "EqCond pattern variables leaked into rule-condition external closure";
  let reversed = EqCond (record field, target) in
  if
    Condition_closure.external_vars_of_conditions
      ~constructor_op:certificate [ "EXTERNAL-EQUALITY-FIELD" ] [ reversed ]
    <> []
  then failwith "reversed EqCond orientation disagreed in external closure";
  let not_ready =
    EqCond (target, record (Var "EXTERNAL-EQUALITY-MISSING"))
  in
  let expected =
    [ "EXTERNAL-EQUALITY-MISSING"; "EXTERNAL-EQUALITY-TARGET" ]
  in
  if
    Condition_closure.external_vars_of_conditions
      ~constructor_op:certificate [] [ not_ready ]
    <> expected
  then failwith "unready EqCond lost conservative external requirements"

let test_rewrite_condition_readiness () =
  let conf = sort "RewriteReadinessConf" in
  let declaration =
    Maude_ir.generated ~origin:(origin "rewrite-readiness")
      (op "rewriteReadyResult"
         [ sort_ref (sort "SpectecTerminal") ] conf ~attrs:[ Ctor ])
  in
  let certificate =
    Condition_pattern_certificate.generated [ declaration ]
  in
  let lhs = App ("rewriteReadyCall", [ Var "REWRITE-SOURCE" ]) in
  let rhs = App ("rewriteReadyResult", [ Var "REWRITE-WITNESS" ]) in
  let condition = RewriteCond (lhs, rhs) in
  let bound =
    Condition_closure.rule_conditions_bound_vars
      ~constructor_op:certificate [ "REWRITE-SOURCE" ] [ condition ]
  in
  if not (List.mem "REWRITE-WITNESS" bound) then
    failwith "ready RewriteCond did not introduce its certified RHS pattern";
  (match
     Condition_closure.rule_conditions_admissible_bound
       ~constructor_op:certificate [ "REWRITE-SOURCE" ] [ condition ]
   with
  | Some bound when List.mem "REWRITE-WITNESS" bound -> ()
  | _ -> failwith "ready RewriteCond was rejected by early admissibility");
  let unready =
    Condition_closure.rule_conditions_bound_vars
      ~constructor_op:certificate [] [ condition ]
  in
  if List.mem "REWRITE-WITNESS" unready then
    failwith "RewriteCond introduced RHS variables before its LHS was bound";
  if
    Condition_closure.rule_conditions_admissible_bound
      ~constructor_op:certificate [] [ condition ]
    <> None
  then failwith "early admissibility accepted an open RewriteCond LHS";
  let uncertified =
    RewriteCond
      (lhs, App ("rewriteComputedResult", [ Var "REWRITE-UNCERTIFIED" ]))
  in
  let bound =
    Condition_closure.rule_conditions_bound_vars
      ~constructor_op:certificate [ "REWRITE-SOURCE" ] [ uncertified ]
  in
  if List.mem "REWRITE-UNCERTIFIED" bound then
    failwith "RewriteCond introduced variables from an uncertified RHS";
  if
    Condition_closure.rule_conditions_admissible_bound
      ~constructor_op:certificate [ "REWRITE-SOURCE" ] [ uncertified ]
    <> None
  then failwith "early admissibility accepted an uncertified RewriteCond RHS"

let test_optional_binding_membership_representation () =
  let optional_typ = IterT (nat_typ, Opt) $ region in
  let witness = typed_var nat_typ "optional_witness" in
  let index = Analysis.Source_index.of_script [] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let env =
    Expr_env.add Expr_env.empty "optional_witness"
      { term = Var "OPTIONAL-WITNESS"
      ; sort = sort "Nat"
      ; typ = nat_typ
      }
  in
  let lower label source =
    let membership = MemE (witness, source) $$ region % (BoolT $ region) in
    match
      Premise_membership.try_lower_ifpr_meme_binding
        Local_name.empty ctx env ~bound_vars:[] ~future_prems:[]
        (origin label) membership witness source
    with
    | Some result, _ -> result.Premise_result.eq_conditions
    | None, _ -> failwith (label ^ " was not recognized as binding membership")
  in
  let present = OptE (Some (nat 7)) $$ region % optional_typ in
  (match lower "optional-present-membership" present with
  | [ MatchCond (Var "OPTIONAL-WITNESS", Const "7") ] -> ()
  | _ -> failwith "flat optional membership did not match the element directly");
  let absent = OptE None $$ region % optional_typ in
  match lower "optional-absent-membership" absent with
  | [ MatchCond (Var "OPTIONAL-WITNESS", Const "eps") ] -> ()
  | _ -> failwith "flat optional absence did not preserve the eps no-hit subject"

let test_binding_membership_retries_after_later_producer () =
  let list_typ = IterT (nat_typ, List) $ region in
  let member_id = "deferred_membership_member" in
  let source_id = "deferred_membership_source" in
  let member = typed_var nat_typ member_id in
  let source = typed_var list_typ source_id in
  let membership =
    IfPr (MemE (member, source) $$ region % (BoolT $ region)) $ region
  in
  let produced = ListE [ nat 7 ] $$ region % list_typ in
  let producer =
    IfPr
      (CmpE (`EqOp, `NatT, source, produced)
       $$ region % (BoolT $ region))
    $ region
  in
  let make_context () =
    let index = Analysis.Source_index.of_script [] in
    Context.create index (Builtin_registry.of_source_index index)
  in
  let env =
    Expr_env.empty
    |> fun env ->
    Expr_env.add env member_id
      { term = Var "DEFERRED-MEMBERSHIP-MEMBER"
      ; sort = sort "Nat"
      ; typ = nat_typ
      }
    |> fun env ->
    Expr_env.add env source_id
      { term = Var "DEFERRED-MEMBERSHIP-SOURCE"
      ; sort = sort "SpectecTerminals"
      ; typ = list_typ
      }
  in
  let deferred_ctx = make_context () in
  (match
     Premise_translate.translate_premise
       ~future_prems:[ producer ] deferred_ctx env ~bound_vars:[]
       (origin "deferred-membership-candidate") membership
   with
  | Deferred (Binding_membership_admissibility, diagnostics) ->
    if not
         (List.exists (fun diagnostic ->
            String.ends_with ~suffix:source_id diagnostic.Diagnostics.reason)
            diagnostics)
    then failwith "binding membership deferral lost its source dependency id"
  | Complete _ | Blocked _ ->
    failwith "binding membership with a later producer was not deferred"
  | Deferred _ ->
    failwith "binding membership used the wrong structured deferral tag");
  if Helper.materialize_static (Context.helpers deferred_ctx) <> [] then
    failwith "deferred binding membership leaked a helper request";
  let ctx = make_context () in
  let result =
    Premise_translate.translate_premises
      ctx env ~bound_terms:[] (origin "deferred-membership-producer")
      [ membership; producer ]
    |> complete_premise "deferred-membership-producer"
  in
  let bound = Premise_result.bound_vars_after result in
  if
    not
      (List.mem "DEFERRED-MEMBERSHIP-SOURCE" bound
       && List.mem "DEFERRED-MEMBERSHIP-MEMBER" bound)
  then failwith "binding membership was not retried after its later producer";
  let helper_names =
    Helper.materialize_static (Context.helpers ctx)
    |> List.filter_map (fun statement ->
      match statement.provenance with
      | Helper name -> Some name
      | Prelude | Source -> None)
    |> List.sort_uniq String.compare
  in
  if List.length helper_names <> 1 then
    failwith "binding membership retry did not commit exactly one helper"

let test_deferred_listn_retries_after_producer () =
  let module_typ = VarT (id "renamed_module_instance", []) $ region in
  let modules_typ = IterT (module_typ, List) $ region in
  let moduleinst = typed_var module_typ "renamed_moduleinst" in
  let modules = typed_var modules_typ "renamed_modules" in
  let repeated =
    IterE (moduleinst, (ListN (nat 1, None), []))
    $$ region % modules_typ
  in
  let field =
    Xl.Atom.Atom "FIELD" $$ region % Xl.Atom.info "regression"
  in
  let record = StrE [ field, nat 0 ] $$ region % module_typ in
  let equality left right =
    IfPr
      (CmpE (`EqOp, `NatT, left, right) $$ region % (BoolT $ region))
    $ region
  in
  let record_typ = StructT [ field, (nat_typ, [], []), [] ] $ region in
  let record_inst = InstD ([], [], record_typ) $ region in
  let record_def =
    TypD (id "renamed_module_instance", [], [ record_inst ]) $ region
  in
  let index = Analysis.Source_index.of_script [ record_def ] in
  let ctx = Context.create index (Builtin_registry.of_source_index index) in
  let env =
    Expr_env.empty
    |> fun env ->
    Expr_env.add env "renamed_moduleinst"
      { term = Var "DEFERRED-MODULEINST"
      ; sort = sort "SpectecTerminal"
      ; typ = module_typ
      }
    |> fun env ->
    Expr_env.add env "renamed_modules"
      { term = Var "DEFERRED-MODULES"
      ; sort = sort "SpectecTerminals"
      ; typ = modules_typ
      }
  in
  let result =
    Premise_translate.translate_premises
      ctx env ~bound_terms:[] (origin "deferred-listn-producer")
      [ equality modules repeated; equality moduleinst record ]
    |> complete_premise "deferred-listn-producer"
  in
  let bound = Premise_result.bound_vars_after result in
  if
    not
      (List.mem "DEFERRED-MODULEINST" bound
       && List.mem "DEFERRED-MODULES" bound)
  then failwith "deferred ListN premise was not retried after its producer";
  let helper_names =
    Helper.materialize_static (Context.helpers ctx)
    |> List.filter_map (fun statement ->
      match statement.provenance with
      | Helper name -> Some name
      | Prelude | Source -> None)
    |> List.sort_uniq String.compare
  in
  if List.length helper_names <> 1 then
    failwith "deferred ListN retry did not commit exactly one helper"

let () =
  test_external_validation_dependency ();
  test_scc_fixed_literal_runtime_guard_retained ();
  test_exists_head_and_tail_success ();
  test_rewrite_exists_head_and_tail_success ();
  test_finite_transitive_proof ();
  test_runtime_truth_query_key ();
  test_runtime_truth_scc_renaming ();
  test_runtime_truth_open_successor ();
  test_open_rules_cannot_prove_zero_successors ();
  test_rooted_subtyping_cut_certificate ();
  test_runtime_truth_iter_local_scope ();
  test_runtime_truth_dependency_schedule ();
  test_runtime_validation_certificate_is_closed_and_use_exact ();
  test_indexed_constructor_successor_certificate ();
  test_successor_certificate_exact_rule ();
  test_anonymous_rule_source_identity ();
  test_anonymous_rule_helper_keys ();
  test_indexed_constructor_nonfinite_source ();
  test_indexed_constructor_ordered_enumeration ();
  test_delegated_indexed_binding_certificate ();
  test_delegated_binding_orientation ();
  test_delegated_binding_blockers ();
  test_delegated_zero_or_one_binding ();
  test_runtime_truth_worklist_key ();
  test_worklist_enabledness_requires_equation_first_failures ();
  test_legacy_truth_enabledness_rejects_equations ();
  test_transitive_support_materialization ();
  test_renamed_synthetic_positive ();
  test_renamed_synthetic_negative ();
  test_renamed_synthetic_cyclic_false ();
  test_direct_successors_cover_transitive_decision ();
  test_constructor_family_completeness ();
  test_open_length_guarded_constructor_is_refutable ();
  test_constructor_family_static_key_isolation ();
  test_utf8_representation_certificate ();
  test_list_rule_traversal ();
  test_zip_rule_order_and_frozen ();
  test_recursive_rule_condition_progress_order ();
  test_zip_binding_traversal ();
  test_builtin_dependency_readiness ();
  test_runtime_ingress_validation ();
  test_head_guard_refutation ();
  test_missing_condition_certificates_blocked ();
  test_head_domain_factoring ();
  test_source_ifpr_total_observers ();
  test_incomplete_sequential_complement_rejected ();
  test_source_indexed_equality_certificate ();
  test_indexed_equality_then_list_binding_complement ();
  test_irrefutable_binding_patterns ();
  test_unproven_matchcond_complement_rejected ();
  test_stuck_call_cannot_refute_equality ();
  test_iter_evaluator_domains ();
  test_clause_proven_indexed_enumeration ();
  test_old_dependent_false_requires_total_boolean ();
  test_blocked_indexed_no_hit_is_transactional ();
  test_context_stage_isolates_constructor_registry ();
  test_rejected_ordinary_iterpr_has_no_helper ();
  test_source_definition_atomicity ();
  test_runtime_truth_source_boolean_observers ();
  test_partial_numeric_operators_cannot_refute_equality ();
  test_partial_destructor_domains_blocked ();
  test_exact_case_constructor_domains ();
  test_length_guarded_case_map_totality ();
  test_ambiguous_case_map_cardinality_blocked ();
  test_failed_proof_keeps_origin_and_lhs_scope ();
  test_synchronized_totality_domain ();
  test_nondecreasing_recursion_rejected ();
  test_guard_else_partition_certificate ();
  test_helper_closure_fixed_point ();
  test_atomic_blocked_helper_emission ();
  test_generated_helper_reachability ();
  test_generated_reachability_typed_dependencies ();
  test_structural_match_pattern_certificate ();
  test_runtime_ingress_contract_validation ();
  test_runtime_ingress_slice_certificate ();
  test_pure_decd_rejects_rule_conditions ();
  test_equality_binding_orientation ();
  test_equality_external_closure_orientation ();
  test_rewrite_condition_readiness ();
  test_optional_binding_membership_representation ();
  test_binding_membership_retries_after_later_producer ();
  test_deferred_listn_retries_after_producer ()
