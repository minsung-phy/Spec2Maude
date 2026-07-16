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
  [ relation "positive_renamed" [ fact "positive-fact" ]
  ; relation "negative_renamed" [ fact "negative-only-fact" ]
  ; relation "cycle_renamed" [ cycle ]
  ; relation_with_result "guarded_renamed" guarded_result [ guarded ]
  ; RelD (id "runtime_seed", [], execution_mixop, nat_typ, [ seed ]) $ region
  ]

let item ?(input_sorts = [ sort "Nat"; sort "Nat" ]) ctx name relation input_terms =
  let request =
    { Runtime_truth_worklist_helper.relation_id = relation
    ; specialization = "nat,nat"
    ; input_terms
    ; input_sorts
    ; phase = Runtime_truth_scc.Goal
    ; mode = Runtime_truth_worklist_helper.Decide
    ; plan = Runtime_truth_scc.plan (Context.function_graph ctx) relation
    }
  in
  { Runtime_truth_worklist_materializer.name
  ; origin = origin name
  ; request
  }

let () =
  let index = Analysis.Source_index.of_script script in
  let builtins = Builtin_registry.of_source_index index in
  let ctx = Context.create index builtins in
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
    ]
  in
  let result = Runtime_truth_worklist_materializer.materialize ctx items in
  let statements =
    match result with
    | Runtime_truth_worklist_materializer.Blocked_result _ -> exit 1
    | Complete_result complete ->
      Runtime_truth_worklist_materializer.complete_statements complete
  in
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
      (Emit.render_term (App (item.name, item.request.input_terms))))
