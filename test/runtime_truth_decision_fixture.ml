open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let list_typ = IterT (nat_typ, List) $ region
let opt_typ = IterT (nat_typ, Opt) $ region
let var_of typ text = VarE (id text) $$ region % typ
let var text = var_of nat_typ text
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ
let origin name = Origin.synthetic ~ast_constructor:"DecisionFixture" name
let mixop = Xl.Mixop.Arg ()

let predicate_mixop =
  let marker = Xl.Atom.Turnstile $$ region % Xl.Atom.info "fixture" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let execution_mixop =
  let marker = Xl.Atom.SqArrow $$ region % Xl.Atom.info "fixture" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let rulepr relation components =
  RulePr (id relation, [], mixop, TupE components $$ region % nat_typ) $ region

let source_rule name head prems =
  RuleD (id name, [], predicate_mixop, head, prems) $ region

let relation name rules =
  RelD (id name, [], predicate_mixop, nat_typ, rules) $ region

let relation_with_result name result rules =
  RelD (id name, [], predicate_mixop, result, rules) $ region

let fact name =
  source_rule name (TupE [ nat 0; nat 0 ] $$ region % nat_typ) []

let script =
  let x = var "x" in
  let left = var "left" in
  let right = var "right" in
  let witness = var "witness" in
  let optional = var_of opt_typ "optional" in
  let lifted = LiftE optional $$ region % list_typ in
  let guarded_result = TupT [ id "sequence", list_typ; id "tag", nat_typ ] $ region in
  let guarded =
    source_rule "guarded" (TupE [ lifted; nat 0 ] $$ region % guarded_result) []
  in
  let cycle =
    source_rule "cycle"
      (TupE [ x; x ] $$ region % nat_typ)
      [ rulepr "cycle_renamed" [ x; x ] ]
  in
  let seeds =
    [ rulepr "positive_renamed" [ var "p"; var "p" ]
    ; rulepr "negative_renamed" [ var "n"; var "n" ]
    ; rulepr "cycle_renamed" [ var "c"; var "c" ]
    ; rulepr "guarded_renamed" [ var_of list_typ "g"; var "gt" ]
    ]
  in
  let seed =
    RuleD (id "seed", [], execution_mixop, var "seed", seeds) $ region
  in
  let target_chain =
    source_rule "target-chain"
      (TupE [ left; right ] $$ region % nat_typ)
      [ rulepr "chain_renamed" [ left; witness ]
      ; rulepr "target_renamed" [ witness; right ]
      ]
  in
  let bool_guard =
    source_rule "bool-guard"
      (TupE [ left; right ] $$ region % nat_typ)
      [ IfPr
          (CmpE (`EqOp, `NatT, left, right)
             $$ region % (BoolT $ region))
          $ region ]
  in
  let generic_transitive =
    source_rule "generic-transitive"
      (TupE [ left; right ] $$ region % nat_typ)
      [ rulepr "finite_domain_renamed" [ witness ]
      ; rulepr "transitive_renamed" [ left; witness ]
      ; rulepr "transitive_renamed" [ witness; right ]
      ]
  in
  [ relation "positive_renamed" [ fact "positive-fact" ]
  ; relation "negative_renamed" [ fact "negative-only-fact" ]
  ; relation "cycle_renamed" [ cycle ]
  ; relation_with_result "guarded_renamed" guarded_result [ guarded ]
  ; relation "target_renamed"
      [ source_rule "target-hit"
          (TupE [ nat 1; nat 9 ] $$ region % nat_typ) [] ]
  ; relation "chain_renamed"
      [ source_rule "seed-hit"
          (TupE [ nat 0; nat 1 ] $$ region % nat_typ) []
      ; source_rule "seed-miss"
          (TupE [ nat 0; nat 2 ] $$ region % nat_typ) []
      ; target_chain
      ]
  ; relation "bool_guard_renamed" [ bool_guard ]
  ; relation "finite_domain_renamed"
      [ source_rule "finite-domain-one" (nat 1) [] ]
  ; relation "transitive_renamed"
      [ generic_transitive
      ; source_rule "generic-base"
          (TupE [ nat 0; nat 1 ] $$ region % nat_typ) []
      ; source_rule "generic-base-next"
          (TupE [ nat 1; nat 2 ] $$ region % nat_typ) []
      ]
  ; RelD (id "runtime_seed", [], execution_mixop, nat_typ, [ seed ]) $ region
  ]

let item
    ?(input_sorts = [ sort "Nat"; sort "Nat" ])
    ?(mode = Runtime_truth_worklist_helper.Decide)
    ctx name relation input_terms =
  let request =
    { Runtime_truth_worklist_helper.relation_id = relation
    ; specialization = "nat,nat"
    ; input_terms
    ; input_sorts
    ; phase = Runtime_truth_scc.Goal
    ; mode
    ; plan = Runtime_truth_scc.plan (Context.function_graph ctx) relation
    }
  in
  { Runtime_truth_worklist_materializer.name
  ; origin = origin name
  ; request
  }

let expect_target_chain_unsupported ctx item =
  match Runtime_truth_worklist_materializer.materialize ctx [ item ] with
  | Runtime_truth_worklist_materializer.Blocked_result [ diagnostic ]
    when diagnostic.Diagnostics.constructor
         = "RuntimeTruthWorklist/target-chain/decision-unsupported"
         && diagnostic.origin.ast_constructor = "RuleD" ->
    ()
  | Runtime_truth_worklist_materializer.Blocked_result diagnostics ->
    failwith
      ("target-chain Decide produced inexact diagnostics:\n"
       ^ Diagnostics.render_all diagnostics)
  | Complete_result _ ->
    failwith "target-chain Decide materialized an unproved false surface"

let helper_request ast_constructor request =
  { Helper_request.kind = Runtime_predicate_truth_worklist request
  ; reason = Runtime_truth_worklist_helper.reason request
  ; origin = Origin.synthetic ~ast_constructor ast_constructor
  }

let declares name statements =
  List.exists (fun statement ->
    match statement.node with
    | OpDecl declaration -> declaration.name = name
    | SortDecl _ | SubsortDecl _ | VarDecl _ | Mb _ | Cmb _
    | Eq _ | Ceq _ | Rl _ | Crl _ -> false) statements

let materialize_capability_isolation ctx =
  let request mode input_terms =
    (item ~mode ctx "RegistryChain" "chain_renamed" input_terms).request
  in
  let prove = request Runtime_truth_worklist_helper.Prove [ Const "0"; Const "9" ] in
  let prove_alpha =
    request Runtime_truth_worklist_helper.Prove [ Const "7"; Const "9" ]
  in
  let decide =
    request Runtime_truth_worklist_helper.Decide [ Const "7"; Const "9" ]
  in
  let helpers = Context.helpers ctx in
  let prove_name =
    Helper.request helpers (helper_request "RegistryChainProve" prove)
  in
  let prove_alpha_name =
    Helper.request helpers (helper_request "RegistryChainProveAlpha" prove_alpha)
  in
  if prove_name <> prove_alpha_name then
    failwith "concrete Prove queries did not share one materialized program";
  let decide_name =
    Helper.request helpers (helper_request "RegistryChainDecide" decide)
  in
  if decide_name = prove_name then
    failwith "Prove and Decide shared one materialized program";
  let registered = Helper.runtime_predicate_truth_worklist_requests helpers in
  let registered_item name mode =
    registered
    |> List.find_map (fun
         (entry_name, entry_origin,
          (entry_request : Runtime_truth_worklist_helper.request)) ->
         if entry_name = name && entry_request.mode = mode then
           Some
             { Runtime_truth_worklist_materializer.name = entry_name
             ; origin = entry_origin
             ; request = entry_request
             }
         else None)
    |> Option.get
  in
  let prove_statements =
    match
      Runtime_truth_worklist_materializer.materialize ctx
        [ registered_item prove_name Runtime_truth_worklist_helper.Prove ]
    with
    | Complete_result complete ->
      Runtime_truth_worklist_materializer.complete_statements complete
    | Blocked_result diagnostics ->
      failwith
        ("valid Prove program was blocked:\n"
         ^ Diagnostics.render_all diagnostics)
  in
  let decide_item =
    registered_item decide_name Runtime_truth_worklist_helper.Decide
  in
  (match Runtime_truth_worklist_materializer.materialize ctx [ decide_item ] with
  | Blocked_result [ diagnostic ]
    when diagnostic.Diagnostics.constructor
         = "RuntimeTruthWorklist/target-chain/decision-unsupported" ->
    ()
  | Blocked_result diagnostics ->
    failwith
      ("capability-isolation Decide produced unexpected diagnostics:\n"
       ^ Diagnostics.render_all diagnostics)
  | Complete_result _ ->
    failwith "target-chain Decide materialized an unproved false surface");
  let blocked_declarations =
    Runtime_truth_worklist_helper.surface
      ~helper_name:decide_name ~origin:decide_item.origin decide_item.request
  in
  if not (declares prove_name prove_statements) then
    failwith "valid Prove program was not materialized";
  if declares decide_name prove_statements then
    failwith "rejected Decide program emitted a definition";
  if not (declares decide_name blocked_declarations) then
    failwith "rejected Decide program did not retain an explicitly blocked surface";
  if declares prove_name blocked_declarations then
    failwith "rejected Decide poisoned the valid Prove surface";
  prove_name, prove, prove_alpha, prove_statements

let search_refuted_declaration helper_name request =
  let invocation =
    Runtime_truth_worklist_helper.invocation ~helper_name request
  in
  let result =
    sort ("RuntimeTruthWorklist" ^ Naming.sort_token helper_name ^ "Conf")
  in
  generated ~provenance:(Helper helper_name)
    ~origin:(origin "RegistryFailedSearch")
    (op invocation.refuted_op [] result ~attrs:[ Ctor ])

let declarations_first statements =
  let declarations, definitions =
    List.partition (fun statement ->
      match statement.node with
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ -> true
      | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ -> false) statements
  in
  declarations @ definitions

let witness_rule (rule : Runtime_truth_scc.rule) =
  let source = rule.source in
  { Runtime_witness_proof.identity = source.identity
  ; relation_id = source.relation_id
  ; rule_id = source.rule_id
  ; origin = source.origin
  ; source_echo = source.source_echo
  ; head = source.head
  ; prems = source.prems
  }

let check_statement_order ctx
    (transitive_item : Runtime_truth_worklist_materializer.item)
    statements =
  let rec declarations_done = function
    | [] -> ()
    | statement :: rest ->
      (match statement.node with
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ ->
        declarations_done rest
      | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ ->
        if
          List.exists
            (fun statement ->
              match statement.node with
              | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ -> true
              | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ -> false)
            rest
        then failwith "runtime truth declaration followed a generated definition")
  in
  let rec find_worker index rule_id = function
    | [] -> None
    | statement :: rest ->
      let found =
        if List.mem ("RuleD/" ^ rule_id) statement.origin.path then
          match statement.node with
          | Crl (Some label, App (_, Const phase :: _), _, _)
            when String.starts_with
                   ~prefix:"transitiveorder-prove-" label ->
            Some (index, phase)
          | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
          | Eq _ | Ceq _ | Rl _ | Crl _ -> None
        else None
      in
      match found with
      | Some found -> Some found
      | None -> find_worker (index + 1) rule_id rest
  in
  let dispatch_phase prefix =
    statements
    |> List.find_map (fun statement ->
         match statement.node with
         | Crl
             ( Some label
             , _
             , _
             , [ RewriteCond (App (_, Const phase :: _), _) ] )
           when String.starts_with ~prefix label ->
           Some phase
         | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
         | Eq _ | Ceq _ | Rl _ | Crl _ -> None)
    |> Option.get
  in
  let ordinary_phase =
    dispatch_phase "transitiveorder-positive-ordinary-"
  in
  let transitive_phase =
    dispatch_phase "transitiveorder-positive-transitive-"
  in
  if ordinary_phase = transitive_phase then
    failwith "positive dispatcher merged Ordinary and Transitive phases";
  let rules =
    Runtime_truth_scc.plan
      (Context.function_graph ctx) "transitive_renamed"
    |> fun plan -> plan.Runtime_truth_scc.sccs
    |> List.concat_map (fun scc -> scc.Runtime_truth_scc.rules)
    |> List.filter (fun (rule : Runtime_truth_scc.rule) ->
         rule.source.relation_id = "transitive_renamed")
  in
  let public_prove, positive_worker =
    statements
    |> List.find_map (fun statement ->
         match statement.node with
         | Crl
             ( Some label
             , App (public_prove, _)
             , _
             , [ RewriteCond (App (positive_worker, _), _) ] )
           when String.starts_with
                  ~prefix:(String.lowercase_ascii transitive_item.name
                           ^ "-positive-ordinary-")
                  label ->
           Some (public_prove, positive_worker)
         | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
         | Eq _ | Ceq _ | Rl _ | Crl _ -> None)
    |> Option.get
  in
  let recursive_calls =
    statements
    |> List.filter_map (fun statement ->
         match statement.node with
         | Crl (_, lhs, _, conditions) ->
           (match lhs with
           | App (op, _) when op = public_prove || op = positive_worker -> None
           | Var _ | Const _ | Qid _ | App _ ->
             let calls =
               conditions
               |> List.filter_map (function
                    | RewriteCond (App (op, _), _)
                      when op = public_prove || op = positive_worker ->
                      Some op
                    | EqCondition _ | RewriteCond _ -> None)
             in
             if List.length calls >= 2 then Some calls else None)
         | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
         | Eq _ | Ceq _ | Rl _ -> None)
    |> List.concat
  in
  if recursive_calls = [] then
    failwith "recursive proof emitted no public RewriteCond";
  if List.exists (( = ) positive_worker) recursive_calls then
    failwith "recursive proof RewriteCond called the positive worker";
  if not (List.for_all (( = ) public_prove) recursive_calls) then
    failwith "recursive proof RewriteCond bypassed the public prove operator";
  let worker_positions =
    rules
    |> List.map (fun (rule : Runtime_truth_scc.rule) ->
         let rule_id = Option.get rule.source.rule_id in
         let index, phase = Option.get (find_worker 0 rule_id statements) in
         let expected =
           if Option.is_some
                (Runtime_witness_proof.transitive_domain (witness_rule rule))
           then transitive_phase
           else ordinary_phase
         in
         if phase <> expected then
           failwith "positive worker phase did not follow structural classification";
         index)
  in
  let rec strictly_increasing = function
    | [] | [ _ ] -> true
    | left :: (right :: _ as rest) ->
      left < right && strictly_increasing rest
  in
  if not (strictly_increasing worker_positions) then
    failwith "positive RuleD workers did not preserve source order";
  let rec find_dispatch index prefix = function
    | [] -> None
    | statement :: rest ->
      let found =
        match statement.node with
        | Crl (Some label, _, _, _) -> String.starts_with ~prefix label
        | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
        | Eq _ | Ceq _ | Rl _ | Crl _ -> false
      in
      if found then Some index else find_dispatch (index + 1) prefix rest
  in
  declarations_done statements;
  match
    find_dispatch 0 "transitiveorder-positive-ordinary-" statements,
    find_dispatch 0 "transitiveorder-positive-transitive-" statements
  with
  | Some ordinary, Some transitive when ordinary < transitive -> ()
  | _ -> failwith "positive dispatcher did not try Ordinary before Transitive"

let print_search marker invocation rhs =
  Printf.printf "red '%s-begin .\n" marker;
  Printf.printf "search [1] %s =>* %s .\n"
    (Emit.render_term invocation.Runtime_truth_worklist_helper.lhs)
    (Emit.render_term rhs);
  Printf.printf "red '%s-end .\n" marker

let print_decide_searches item =
  match item.Runtime_truth_worklist_materializer.request.mode with
  | Runtime_truth_worklist_helper.Prove -> ()
  | Decide ->
    let invocation =
      Runtime_truth_worklist_helper.invocation
        ~helper_name:item.name item.request
    in
    let marker = "search-" ^ String.lowercase_ascii item.name in
    print_search (marker ^ "-proved") invocation invocation.proved_rhs;
    print_search (marker ^ "-refuted") invocation invocation.refuted_rhs

let () =
  let index = Analysis.Source_index.of_script script in
  let builtins = Builtin_registry.of_source_index index in
  let ctx = Context.create index builtins in
  let rejected =
    [ item ctx "MixedChainDecide" "chain_renamed" [ Const "0"; Const "9" ]
    ; item ctx "ZeroSeedChainDecide" "chain_renamed" [ Const "7"; Const "9" ]
    ]
  in
  List.iter (expect_target_chain_unsupported ctx) rejected;
  let registry_name, registry_success, registry_failed, registry_statements =
    materialize_capability_isolation ctx
  in
  let items =
    [ item ctx "Positive" "positive_renamed" [ Const "0"; Const "0" ]
    ; item ctx "Negative" "negative_renamed" [ Const "0"; Const "1" ]
    ; item ctx "Cyclic" "cycle_renamed" [ Const "0"; Const "0" ]
    ; item ~input_sorts:[ sort "SpectecTerminals"; sort "Nat" ]
        ctx "GuardProved" "guarded_renamed" [ Const "eps"; Const "0" ]
    ; item ~input_sorts:[ sort "SpectecTerminals"; sort "Nat" ]
        ctx "GuardRefuted" "guarded_renamed"
        [ App ("_ _", [ Const "0"; Const "1" ]); Const "0" ]
    ; item ~input_sorts:[ sort "SpectecTerminals"; sort "Nat" ]
        ctx "GuardMismatch" "guarded_renamed" [ Const "eps"; Const "1" ]
    ; item ctx "BoolGuardTrue" "bool_guard_renamed" [ Const "0"; Const "0" ]
    ; item ctx "BoolGuardFalse" "bool_guard_renamed" [ Const "0"; Const "1" ]
    ; item ~mode:Runtime_truth_worklist_helper.Prove
        ctx "TransitiveOrder" "transitive_renamed" [ Const "0"; Const "1" ]
    ; item ~mode:Runtime_truth_worklist_helper.Prove
        ctx "TransitiveClosure" "transitive_renamed" [ Const "0"; Const "2" ]
    ]
  in
  let result = Runtime_truth_worklist_materializer.materialize ctx items in
  let direct_statements =
    match result with
    | Runtime_truth_worklist_materializer.Blocked_result diagnostics ->
      prerr_endline (Diagnostics.render_all diagnostics);
      exit 1
    | Complete_result complete ->
      Runtime_truth_worklist_materializer.complete_statements complete
  in
  let transitive_item =
    items
    |> List.find (fun (item : Runtime_truth_worklist_materializer.item) ->
         item.name = "TransitiveClosure")
  in
  let statements =
    search_refuted_declaration registry_name registry_failed
    :: registry_statements @ direct_statements
    |> declarations_first
  in
  check_statement_order ctx transitive_item statements;
  let module_ =
    { name = "RUNTIME-TRUTH-DECISION-FIXTURE"
    ; kind = System
    ; imports = Prelude.imports
    ; statements = Prelude.statements @ statements
    }
  in
  print_string (Emit.render_module module_);
  items
  |> List.iter (fun (item : Runtime_truth_worklist_materializer.item) ->
    Printf.printf "rew %s .\n"
      (Emit.render_term (App (item.name, item.request.input_terms))));
  Printf.printf "rew %s .\n"
    (Emit.render_term (App (registry_name, registry_success.input_terms)));
  List.iter print_decide_searches items;
  let failed_invocation =
    Runtime_truth_worklist_helper.invocation
      ~helper_name:registry_name registry_failed
  in
  print_search "search-registry-failed-proved"
    failed_invocation failed_invocation.proved_rhs;
  print_search "search-registry-failed-refuted"
    failed_invocation failed_invocation.refuted_rhs
