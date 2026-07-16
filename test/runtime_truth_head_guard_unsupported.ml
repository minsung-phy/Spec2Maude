open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let var text = VarE (id text) $$ region % nat_typ
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ
let origin = Origin.synthetic ~ast_constructor:"HeadGuardFixture" "unsupported"

let marker it = it $$ region % Xl.Atom.info "fixture"

let predicate_mixop =
  Xl.Mixop.Infix
    (Xl.Mixop.Arg (), marker Xl.Atom.Turnstile, Xl.Mixop.Arg ())

let execution_mixop =
  Xl.Mixop.Infix
    (Xl.Mixop.Arg (), marker Xl.Atom.SqArrow, Xl.Mixop.Arg ())

let script =
  let hidden = id "hidden" in
  let call =
    CallE (id "opaque", [ ExpA (var hidden.it) $ region ])
    $$ region % nat_typ
  in
  let guarded =
    RuleD
      (id "guarded", [ ExpP (hidden, nat_typ) $ region ],
       predicate_mixop, TupE [ call; nat 0 ] $$ region % nat_typ, [])
    $ region
  in
  let seed_premise =
    RulePr
      (id "guarded_renamed", [], Xl.Mixop.Arg (),
       TupE [ var "left"; var "right" ] $$ region % nat_typ)
    $ region
  in
  [ DecD
      (id "opaque", [ ExpP (id "value", nat_typ) $ region ], nat_typ, [])
    $ region
  ; RelD
      (id "guarded_renamed", [], predicate_mixop, nat_typ, [ guarded ])
    $ region
  ; RelD
      (id "runtime_seed", [], execution_mixop, nat_typ,
       [ RuleD (id "seed", [], execution_mixop, var "seed", [ seed_premise ])
         $ region ])
    $ region
  ]

let () =
  let index = Analysis.Source_index.of_script script in
  let builtins = Builtin_registry.of_source_index index in
  let ctx = Context.create index builtins in
  let request =
    { Runtime_truth_worklist_helper.relation_id = "guarded_renamed"
    ; specialization = "nat,nat"
    ; input_terms = [ Const "0"; Const "0" ]
    ; input_sorts = [ sort "Nat"; sort "Nat" ]
    ; phase = Runtime_truth_scc.Goal
    ; mode = Runtime_truth_worklist_helper.Decide
    ; plan = Runtime_truth_scc.plan
        (Context.function_graph ctx) "guarded_renamed"
    }
  in
  let item =
    { Runtime_truth_worklist_materializer.name = "UnsupportedGuard"
    ; origin
    ; request
    }
  in
  let result = Runtime_truth_worklist_materializer.materialize ctx [ item ] in
  match result with
  | Complete_result _ ->
    failwith "blocked worklist retained a complete public helper surface"
  | Blocked_result diagnostics ->
    if not
         (List.exists
            (fun diagnostic ->
              diagnostic.Diagnostics.constructor
              = "RuntimeTruthWorklist/false/head-guard-complement"
              && Diagnostics.is_fatal diagnostic)
            diagnostics)
    then
      failwith "non-total matched-head guard did not become explicit Unsupported"
