open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let seq_typ = IterT (nat_typ, List) $ region
let var ?(typ = nat_typ) text = VarE (id text) $$ region % typ
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ

let execution_mixop =
  let marker = Xl.Atom.SqArrow $$ region % Xl.Atom.info "rewrite-regression" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let annotation relation_id =
  let hint =
    { hintid = id "maude_equational_view"
    ; hintexp = El.Ast.BoolE true $ region
    }
  in
  HintD (RelH (id relation_id, [ hint ]) $ region) $ region

let relation_typ output_typ =
  TupT [ id "input", nat_typ; id "output", output_typ ] $ region

let rule name ?(prems = []) input output =
  let binds =
    [ ExpP (id "x", nat_typ) $ region
    ; ExpP (id "ys", seq_typ) $ region
    ]
  in
  RuleD
    (id name, binds, execution_mixop,
     TupE [ input; output ] $$ region % relation_typ output.note,
     prems)
  $ region

let relation name output_typ rules =
  RelD (id name, [], execution_mixop, relation_typ output_typ, rules) $ region

let rule_prem relation_name input output output_typ =
  RulePr
    (id relation_name, [], execution_mixop,
     TupE [ input; output ] $$ region % relation_typ output_typ)
  $ region

let exp_param name typ = ExpP (id name, typ) $ region
let exp_arg exp = ExpA exp $ region

let call name typ args =
  CallE (id name, List.map exp_arg args) $$ region % typ

let clause binds args rhs prems =
  DefD (binds, List.map exp_arg args, rhs, prems) $ region

let definition name params result clauses =
  DecD (id name, params, result, clauses) $ region

let is_relevant_fatal diagnostic =
  Diagnostics.is_fatal diagnostic
  && diagnostic.Diagnostics.constructor <> "BuiltinBackend/representation"

let has_fatal result = List.exists is_relevant_fatal result.Driver.diagnostics

let require_no_fatal message result =
  if has_fatal result then
    failwith
      (message ^ "\n"
       ^ (result.Driver.diagnostics
          |> List.filter is_relevant_fatal
          |> Diagnostics.render_all))

let root = function App (name, _) -> Some name | Var _ | Const _ | Qid _ -> None

let contains text fragment =
  let rec search index =
    index + String.length fragment <= String.length text
    && (String.sub text index (String.length fragment) = fragment
        || search (index + 1))
  in
  fragment = "" || search 0

let statements_for op_name result =
  result.Driver.module_.statements
  |> List.filter (fun statement ->
    match statement.node with
    | Rl (_, lhs, _) | Crl (_, lhs, _, _) | Eq (lhs, _, _) | Ceq (lhs, _, _, _) ->
      root lhs = Some op_name
    | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _ -> false)

let direct_fixture ?(annotated = true) () =
  let relation_name = "renamed_motion" in
  let x = var "x" in
  let ys = var ~typ:seq_typ "ys" in
  let empty = ListE [] $$ region % seq_typ in
  let relation_def = relation relation_name seq_typ [ rule "carry" x empty ] in
  let premise = rule_prem relation_name x ys seq_typ in
  let def =
    definition "renamed_walk"
      [ exp_param "x" nat_typ ] seq_typ
      [ clause [ exp_param "x" nat_typ; exp_param "ys" seq_typ ] [ x ] ys [ premise ] ]
  in
  relation_def :: (if annotated then [ annotation relation_name ] else []) @ [ def ]

let test_ordinary_relation_and_rewrite_wrapper () =
  let result = Driver.translate (direct_fixture ()) in
  require_no_fatal "annotated neutral fixture did not translate" result;
  let rendered = Emit.render_module result.module_ in
  [ "REWRITE_RESULT"; "PATTERN_WILD"; "PATTERN_ITER"; "LOC_" ]
  |> List.iter (fun stale ->
    if contains rendered stale then
      failwith ("path/location-derived generated variable remains: " ^ stale));
  let relation_op = Naming.relation_op (id "renamed_motion") in
  let definition_op = Naming.definition_op (id "renamed_walk") in
  let relation_rules = statements_for relation_op result in
  if List.length relation_rules <> 1 then
    failwith "annotated relation did not emit every source RuleD";
  if not (List.for_all (fun statement -> match statement.node with Rl _ | Crl _ -> true | _ -> false) relation_rules) then
    failwith "annotated relation source rules were not emitted as rl/crl";
  let wrappers = statements_for definition_op result in
  if List.length wrappers <> 1 then failwith "rewrite-backed DecD clause was not emitted";
  if not (List.for_all (fun statement -> match statement.node with Rl _ | Crl _ -> true | _ -> false) wrappers) then
    failwith "rewrite-backed DecD clause remained equational";
  let has_frozen_wrapper =
    List.exists (fun statement ->
      match statement.node with
      | OpDecl { name; result = conf; attrs = [ Frozen [ 1 ] ]; _ }
        when name = definition_op -> sort_name conf <> "SpectecTerminals"
      | _ -> false)
      result.module_.statements
  in
  if not has_frozen_wrapper then
    failwith "promoted DecD lacks a distinct frozen result configuration sort";
  if
    result.module_.statements
    |> List.exists (fun statement ->
      match statement.node with
      | OpDecl declaration ->
        let name = declaration.name in
        String.length name >= 5 && String.sub name (String.length name - 5) 5 = "-view"
      | _ -> false)
  then failwith "separate unevaluated relation -view operator survived"

let test_unannotated_stays_unsupported () =
  let result = Driver.translate (direct_fixture ~annotated:false ()) in
  if not (has_fatal result) then
    failwith "unannotated execution-dependent DecD was promoted"

let graph_fixture () =
  let relation_name = "renamed_seed" in
  let x = var "x" in
  let y = var "y" in
  let premise = rule_prem relation_name x y nat_typ in
  let a_call = call "renamed_a" nat_typ [ x ] in
  let b_call = call "renamed_b" nat_typ [ x ] in
  let a =
    definition "renamed_a" [ exp_param "x" nat_typ ] nat_typ
      [ clause [ exp_param "x" nat_typ ] [ x ] b_call [] ]
  in
  let b =
    definition "renamed_b" [ exp_param "x" nat_typ ] nat_typ
      [ clause [ exp_param "x" nat_typ; exp_param "y" nat_typ ] [ x ] a_call [ premise ] ]
  in
  let caller =
    definition "renamed_caller" [ exp_param "x" nat_typ ] nat_typ
      [ clause [ exp_param "x" nat_typ ] [ x ] a_call [] ]
  in
  [ relation relation_name nat_typ [ rule "identity" x x ]
  ; annotation relation_name
  ; RecD [ a; b ] $ region
  ; caller
  ]

let test_scc_and_transitive_callers () =
  let index = Analysis.Source_index.of_script (graph_fixture ()) in
  let graph = Analysis.Function_graph.build index in
  [ "renamed_a"; "renamed_b"; "renamed_caller" ]
  |> List.iter (fun name ->
    if not (Analysis.Function_graph.definition_is_rewrite_backed graph name) then
      failwith ("rewrite dependency did not promote " ^ name));
  let result = Driver.translate (graph_fixture ()) in
  require_no_fatal "recursive promoted SCC did not translate" result;
  let rendered = Emit.render_module result.module_ in
  if not (contains rendered "RESULT1:") then
    failwith "rewrite-backed clause did not use a local RESULT ordinal";
  [ "renamed_a"; "renamed_b"; "renamed_caller" ]
  |> List.iter (fun name ->
    let op_name = Naming.definition_op (id name) in
    if statements_for op_name result = [] then
      failwith ("promoted definition has no operational wrapper: " ^ name))

let test_condition_order_and_binding () =
  let result = Driver.translate (graph_fixture ()) in
  let op_name = Naming.definition_op (id "renamed_b") in
  let ordered =
    statements_for op_name result
    |> List.exists (fun statement ->
      match statement.node with
      | Crl (_, _, _, conditions) ->
        let rec loop saw_relation = function
          | [] -> false
          | RewriteCond (App (name, _), rhs) :: rest ->
            let saw_relation = saw_relation || name = Naming.relation_op (id "renamed_seed") in
            if saw_relation && name = Naming.definition_op (id "renamed_a")
               && Condition_closure.term_vars rhs <> []
            then true
            else loop saw_relation rest
          | _ :: rest -> loop saw_relation rest
        in
        loop false conditions
      | _ -> false)
  in
  if not ordered then
    failwith "rewrite conditions were not ordered with RHS patterns binding later variables"

let test_malformed_singleton_output () =
  let malformed =
    RuleD (id "malformed", [], execution_mixop, nat 0, []) $ region
  in
  let script =
    [ relation "renamed_malformed" nat_typ [ malformed ]
    ; annotation "renamed_malformed"
    ]
  in
  let result = Driver.translate script in
  if not (has_fatal result) then
    failwith "malformed annotated input/output bundle was accepted"

let test_obvious_nondeterminism () =
  let first =
    RuleD
      (id "first", [], execution_mixop,
       TupE [ nat 0; nat 1 ] $$ region % relation_typ nat_typ, [])
    $ region
  in
  let second =
    RuleD
      (id "second", [], execution_mixop,
       TupE [ nat 0; nat 2 ] $$ region % relation_typ nat_typ, [])
    $ region
  in
  let result =
    Driver.translate
      [ relation "renamed_nondeterministic" nat_typ [ first; second ]
      ; annotation "renamed_nondeterministic"
      ]
  in
  if not (has_fatal result) then
    failwith "obviously incompatible unconditional outputs were accepted"

let overlap_result first_input first_output second_input second_output =
  let first =
    RuleD
      (id "first-overlap", [], execution_mixop,
       TupE [ first_input; first_output ] $$ region % relation_typ nat_typ, [])
    $ region
  in
  let second =
    RuleD
      (id "second-overlap", [], execution_mixop,
       TupE [ second_input; second_output ] $$ region % relation_typ nat_typ, [])
    $ region
  in
  Driver.translate
    [ relation "renamed_overlap" nat_typ [ first; second ]
    ; annotation "renamed_overlap"
    ]

let test_structural_input_overlap () =
  let result = overlap_result (var "left") (nat 1) (nat 0) (nat 2) in
  if not (has_fatal result) then
    failwith "variable-vs-literal input overlap was accepted";
  let tag = Xl.Atom.Atom "RENAMED" $$ region % Xl.Atom.info "overlap" in
  let constructor = Xl.Mixop.Seq [ Xl.Mixop.Atom tag; Xl.Mixop.Arg () ] in
  let constructor_typ = VarT (id "renamed_constructor_category", []) $ region in
  let wrapped = CaseE (constructor, nat 0) $$ region % constructor_typ in
  let result = overlap_result (var "left") (nat 1) wrapped (nat 2) in
  if not (has_fatal result) then
    failwith "variable-vs-constructor input overlap was accepted"

let test_alpha_equivalent_outputs () =
  let result = overlap_result (var "left") (var "left") (var "right") (var "right") in
  require_no_fatal "alpha-equivalent unconditional outputs conflicted" result

let provenance_context () =
  let index = Analysis.Source_index.of_script (graph_fixture ()) in
  Context.create index (Builtin_registry.of_source_index index)

let has_diagnostic constructor diagnostics =
  List.exists (fun diagnostic ->
    diagnostic.Diagnostics.constructor = constructor) diagnostics

let test_missing_rewrite_provenance () =
  let ctx = provenance_context () in
  let term = App (Naming.definition_op (id "renamed_a"), [ Const "0" ]) in
  let result, _ =
    Decd_rewrite_condition.lower_term ctx
      (Origin.synthetic ~ast_constructor:"CallE" "missing-provenance")
      Local_name.empty term
  in
  if not (has_diagnostic
            "DecD/rewrite-backed/CallE/missing-provenance" result.diagnostics)
  then failwith "rewrite-backed call without structured provenance was accepted"

let test_ambiguous_rewrite_provenance () =
  let ctx = provenance_context () in
  let term = App (Naming.definition_op (id "renamed_a"), [ Const "0" ]) in
  Context.record_definition_call ctx term
    (Analysis.Function_graph.plain_identity "renamed_a");
  Context.record_definition_call ctx term
    (Analysis.Function_graph.plain_identity "renamed_b");
  let result, _ =
    Decd_rewrite_condition.lower_term ctx
      (Origin.synthetic ~ast_constructor:"CallE" "ambiguous-provenance")
      Local_name.empty term
  in
  if not (has_diagnostic
            "DecD/rewrite-backed/CallE/ambiguous-provenance" result.diagnostics)
  then failwith "rewrite-backed call with merged specialization provenance was accepted"

let binding_membership_call_fixture () =
  let input = var "membership_input" in
  let witness = var "membership_witness" in
  let source_name = "renamed_membership_source" in
  let consumer_name = "renamed_membership_consumer" in
  let source =
    definition source_name [ exp_param "membership_input" nat_typ ] seq_typ
      [ clause [ exp_param "membership_input" nat_typ ] [ input ]
          (ListE [ input; nat 1 ] $$ region % seq_typ) [] ]
  in
  let source_call = call source_name seq_typ [ input ] in
  let premise =
    IfPr
      (MemE (witness, source_call) $$ region % (BoolT $ region))
    $ region
  in
  let consumer =
    definition consumer_name [ exp_param "membership_input" nat_typ ] nat_typ
      [ clause
          [ exp_param "membership_input" nat_typ
          ; exp_param "membership_witness" nat_typ
          ]
          [ input ] witness [ premise ]
      ]
  in
  source_name, consumer_name, [ source; consumer ]

let test_binding_membership_call_promotes_and_searches () =
  let source_name, consumer_name, script = binding_membership_call_fixture () in
  let index = Analysis.Source_index.of_script script in
  let graph = Analysis.Function_graph.build index in
  if not (Analysis.Function_graph.definition_is_rewrite_backed graph consumer_name) then
    failwith "binding membership over a list CallE did not promote its DecD";
  let result = Driver.translate script in
  require_no_fatal "binding membership CallE fixture did not translate" result;
  let source_op = Naming.definition_op (id source_name) in
  let consumer_op = Naming.definition_op (id consumer_name) in
  let helper_names =
    result.module_.statements
    |> List.filter_map (fun statement ->
      match statement.provenance with
      | Helper name -> Some name
      | Prelude | Source -> None)
    |> List.sort_uniq String.compare
  in
  let uses_witness_search =
    statements_for consumer_op result
    |> List.exists (fun statement ->
      match statement.node with
      | Crl (_, _, _, conditions) ->
        List.exists (function
          | RewriteCond
              (App (helper, [ App (callee, _) ]), App (result_op, [ Var _ ])) ->
            callee = source_op
            && List.mem helper helper_names
            && result_op =
                 Naming.helper_companion ~role:"membership-result" helper
          | EqCondition _ | RewriteCond _ -> false) conditions
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
      | Eq _ | Ceq _ | Rl _ -> false)
  in
  if not uses_witness_search then
    failwith "list CallE binding membership bypassed the tagged witness helper"

let term_contains_op expected term =
  let rec contains = function
    | App (name, args) ->
      name = expected || List.exists contains args
    | Var _ | Const _ | Qid _ -> false
  in
  contains term

let test_execution_relation_calls_rewrite_backed_definition () =
  let _, consumer_name, definitions = binding_membership_call_fixture () in
  let input = var "relation_input" in
  let output = var "relation_output" in
  let consumer_call = call consumer_name nat_typ [ input ] in
  let premise =
    IfPr
      (CmpE (`EqOp, `NatT, output, consumer_call)
       $$ region % (BoolT $ region))
    $ region
  in
  let relation_name = "renamed_membership_relation" in
  let relation_rule =
    RuleD
      (id "direct-call",
       [ exp_param "relation_input" nat_typ
       ; exp_param "relation_output" nat_typ
       ],
       execution_mixop,
       TupE [ input; output ] $$ region % relation_typ nat_typ,
       [ premise ])
    $ region
  in
  let result =
    Driver.translate
      (definitions @ [ relation relation_name nat_typ [ relation_rule ] ])
  in
  require_no_fatal
    "execution RelD caller of rewrite-backed DecD did not translate" result;
  let callee = Naming.definition_op (id consumer_name) in
  let relation_op = Naming.relation_op (id relation_name) in
  let has_rewrite_then_match =
    statements_for relation_op result
    |> List.exists (fun statement ->
      match statement.node with
      | Crl (_, _, _, conditions) ->
        let rec loop = function
          | RewriteCond (App (name, _), result) :: rest when name = callee ->
            List.exists (function
              | EqCondition (MatchCond (Var _, subject)) -> subject = result
              | EqCondition _ | RewriteCond _ -> false) rest
          | _ :: rest -> loop rest
          | [] -> false
        in
        loop conditions
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
      | Eq _ | Ceq _ | Rl _ -> false)
  in
  if not has_rewrite_then_match then
    failwith "execution RelD kept a rewrite-backed DecD call as a match subject";
  let has_frozen_match_subject =
    statements_for relation_op result
    |> List.exists (fun statement ->
      match statement.node with
      | Crl (_, _, _, conditions) ->
        List.exists (function
          | EqCondition (MatchCond (_, subject)) -> term_contains_op callee subject
          | EqCondition _ | RewriteCond _ -> false) conditions
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _ | Mb _ | Cmb _
      | Eq _ | Ceq _ | Rl _ -> false)
  in
  if has_frozen_match_subject then
    failwith "MatchCond subject still contains a rewrite-backed definition call"

let () =
  test_ordinary_relation_and_rewrite_wrapper ();
  test_unannotated_stays_unsupported ();
  test_scc_and_transitive_callers ();
  test_condition_order_and_binding ();
  test_malformed_singleton_output ();
  test_obvious_nondeterminism ();
  test_structural_input_overlap ();
  test_alpha_equivalent_outputs ();
  test_missing_rewrite_provenance ();
  test_ambiguous_rewrite_provenance ();
  test_binding_membership_call_promotes_and_searches ();
  test_execution_relation_calls_rewrite_backed_definition ()
