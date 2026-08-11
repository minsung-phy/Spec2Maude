open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let bool_typ = BoolT $ region
let text_typ = TextT $ region
let seq_typ = IterT (nat_typ, List) $ region
let nested_typ = IterT (seq_typ, List) $ region

let param name typ = ExpP (id name, typ) $ region
let typ_param name = TypP (id name) $ region
let var name typ = VarE (id name) $$ region % typ
let arg exp = ExpA exp $ region

let declaration name params result =
  DecD (id name, params, result, []) $ region

let inverse_hint source target =
  let hint =
    { hintid = id "inverse"
    ; hintexp = El.Ast.VarE (id target, []) $ region
    }
  in
  HintD (DecH (id source, [ hint ]) $ region) $ region

let status source script =
  script
  |> Analysis.Source_index.of_script
  |> Analysis.Function_graph.build
  |> fun graph -> Analysis.Function_graph.definition_inverse_status graph source

let context script =
  let index = Analysis.Source_index.of_script script in
  Context.create index (Builtin_registry.of_source_index index)

let origin name = Origin.synthetic ~ast_constructor:"InverseMetadataRegression" name

let binding term typ sort =
  { Expr_env.term = Var term; typ; sort }

let add_sequence env source term typ =
  Expr_env.add env source (binding term typ (sort "SpectecTerminals"))

let add_nat env source term =
  Expr_env.add env source (binding term nat_typ (sort "Nat"))

let equality left right =
  CmpE (`EqOp, `NatT, left, right) $$ region % bool_typ

let contains text fragment =
  let rec search index =
    index + String.length fragment <= String.length text
    && (String.sub text index (String.length fragment) = fragment
        || search (index + 1))
  in
  fragment = "" || search 0

let assert_no_inverse_helper label ctx =
  let rendered =
    Helper.materialize_static (Context.helpers ctx)
    |> List.map Emit.render_generated
    |> String.concat "\n"
  in
  if contains rendered "helper.unzip2" || contains rendered "helper.decode-chunks" then
    failwith (label ^ " left an orphan inverse helper")

let assert_bound_fallback label ctx env bound_vars comparison =
  let premise = IfPr comparison $ region in
  (match
     Premise_translate.translate_premise
       ctx env ~bound_vars (origin (label ^ "-ordinary")) premise
   with
  | Premise_result.Complete result ->
    if Premise_result.eq_conditions result = [] then
      failwith (label ^ " did not continue to ordinary equality lowering")
  | Blocked diagnostics | Deferred (_, diagnostics) ->
    failwith
      (label ^ " did not fall back to ordinary equality:\n"
       ^ Diagnostics.render_all diagnostics));
  assert_no_inverse_helper label ctx

let test_unique_omission () =
  let forward =
    declaration "neutral_forward"
      [ param "left" nat_typ; param "missing" bool_typ ] text_typ
  in
  let inverse =
    declaration "neutral_inverse"
      [ param "left" nat_typ; param "result" text_typ ] bool_typ
  in
  match status "neutral_forward"
          [ forward; inverse; inverse_hint "neutral_forward" "neutral_inverse" ] with
  | Analysis.Function_graph.Valid_inverse inverse
    when inverse.inverse_id = "neutral_inverse"
         && inverse.omitted_param_index = 1 -> ()
  | _ -> failwith "unique omitted runtime parameter was not retained"

let test_absolute_omission_after_type_parameter () =
  let forward =
    declaration "typed_forward"
      [ typ_param "X"; param "missing" bool_typ ] text_typ
  in
  let inverse =
    declaration "typed_inverse"
      [ typ_param "X"; param "result" text_typ ] bool_typ
  in
  match status "typed_forward"
          [ forward; inverse; inverse_hint "typed_forward" "typed_inverse" ] with
  | Analysis.Function_graph.Valid_inverse inverse
    when inverse.omitted_param_index = 1 -> ()
  | _ -> failwith "omitted parameter index ignored the preceding TypP"

let test_ambiguous_omission () =
  let forward =
    declaration "ambiguous_forward"
      [ param "same" nat_typ; param "same" nat_typ ] text_typ
  in
  let inverse =
    declaration "ambiguous_inverse"
      [ param "same" nat_typ; param "result" text_typ ] nat_typ
  in
  match status "ambiguous_forward"
          [ forward; inverse; inverse_hint "ambiguous_forward" "ambiguous_inverse" ] with
  | Analysis.Function_graph.Invalid_inverse { reason; _ }
    when String.starts_with ~prefix:"inverse target `ambiguous_inverse` is compatible with more than one" reason -> ()
  | _ -> failwith "ambiguous omitted runtime parameters were accepted"

let test_missing_omission () =
  let forward =
    declaration "invalid_forward"
      [ param "left" nat_typ; param "missing" bool_typ ] text_typ
  in
  let inverse =
    declaration "invalid_inverse"
      [ param "wrong" bool_typ; param "result" text_typ ] bool_typ
  in
  match status "invalid_forward"
          [ forward; inverse; inverse_hint "invalid_forward" "invalid_inverse" ] with
  | Analysis.Function_graph.Invalid_inverse _ -> ()
  | _ -> failwith "zero compatible omitted runtime parameters were accepted"

let pair_call name =
  let left = var "left" nat_typ in
  let right = var "right" nat_typ in
  let lefts = var "lefts" seq_typ in
  let rights = var "rights" seq_typ in
  let pair = ListE [ left; right ] $$ region % seq_typ in
  let chunks =
    IterE
      (pair, (List, [ id "left", lefts; id "right", rights ]))
    $$ region % nested_typ
  in
  CallE (id name, [ arg chunks ]) $$ region % seq_typ

let invalid_pair_script () =
  [ declaration "pair_forward" [ param "chunks" nested_typ ] seq_typ
  ; declaration "pair_inverse" [ param "wrong" nat_typ ] nested_typ
  ; inverse_hint "pair_forward" "pair_inverse"
  ]

let test_bound_pair_falls_back () =
  let ctx = context (invalid_pair_script ()) in
  let call = pair_call "pair_forward" in
  let known = var "known" seq_typ in
  let comparison = equality call known in
  let env =
    Expr_env.empty
    |> fun env -> add_sequence env "lefts" "LEFTS:SpectecTerminals" seq_typ
    |> fun env -> add_sequence env "rights" "RIGHTS:SpectecTerminals" seq_typ
    |> fun env -> add_sequence env "known" "KNOWN:SpectecTerminals" seq_typ
  in
  let bound_vars =
    [ "LEFTS:SpectecTerminals"
    ; "RIGHTS:SpectecTerminals"
    ; "KNOWN:SpectecTerminals"
    ]
  in
  assert_bound_fallback
    "bound-pair-fallback"
    ctx env bound_vars comparison

let concatn_call name bytes_name source_typ =
  let count = var "count" nat_typ in
  let width = var "width" nat_typ in
  let element = var "element" nat_typ in
  let source = var "source" source_typ in
  let bytes =
    CallE (id bytes_name, [ arg element ]) $$ region % seq_typ
  in
  let chunks =
    IterE
      (bytes, (ListN (count, None), [ id "element", source ]))
    $$ region % nested_typ
  in
  CallE (id name, [ arg chunks; arg width ]) $$ region % seq_typ

let invalid_concatn_script () =
  [ declaration "element_bytes" [ param "element" nat_typ ] seq_typ
  ; declaration "concatn_forward"
      [ param "chunks" nested_typ; param "width" nat_typ ] seq_typ
  ; declaration "concatn_inverse" [ param "wrong" nat_typ ] nested_typ
  ; inverse_hint "concatn_forward" "concatn_inverse"
  ]

let test_bound_concatn_falls_back () =
  let count = var "count" nat_typ in
  let source_typ = IterT (nat_typ, ListN (count, None)) $ region in
  let ctx = context (invalid_concatn_script ()) in
  let call = concatn_call "concatn_forward" "element_bytes" source_typ in
  let known = var "known" seq_typ in
  let comparison = equality call known in
  let env =
    Expr_env.empty
    |> fun env -> add_sequence env "source" "SOURCE:SpectecTerminals" source_typ
    |> fun env -> add_sequence env "known" "KNOWN:SpectecTerminals" seq_typ
    |> fun env -> add_nat env "count" "COUNT:Nat"
    |> fun env -> add_nat env "width" "WIDTH:Nat"
  in
  let bound_vars =
    [ "SOURCE:SpectecTerminals"; "KNOWN:SpectecTerminals"; "COUNT:Nat"; "WIDTH:Nat" ]
  in
  assert_bound_fallback
    "bound-concatn-fallback"
    ctx env bound_vars comparison

let assert_active_invalid label ctx env bound_vars comparison =
  let premise = IfPr comparison $ region in
  (match
     Premise_translate.translate_premise
       ctx env ~bound_vars (origin label) premise
   with
  | Premise_result.Blocked diagnostics
    when List.exists Diagnostics.is_fatal diagnostics -> ()
  | Blocked _ -> failwith (label ^ " blocked without fatal Invalid_inverse")
  | Deferred _ -> failwith (label ^ " deferred its Invalid_inverse demand")
  | Complete _ -> failwith (label ^ " lost its Invalid_inverse demand"));
  assert_no_inverse_helper label ctx

let test_unbound_invalid_demands_stay_fatal () =
  let pair_ctx = context (invalid_pair_script ()) in
  let pair = pair_call "pair_forward" in
  let known = var "known" seq_typ in
  let pair_env =
    add_sequence Expr_env.empty "known" "KNOWN:SpectecTerminals" seq_typ
  in
  assert_active_invalid
    "unbound-invalid-pair"
    pair_ctx pair_env [ "KNOWN:SpectecTerminals" ]
    (equality pair known);
  let count = var "count" nat_typ in
  let source_typ = IterT (nat_typ, ListN (count, None)) $ region in
  let concatn_ctx = context (invalid_concatn_script ()) in
  let concatn = concatn_call "concatn_forward" "element_bytes" source_typ in
  let concatn_env =
    Expr_env.empty
    |> fun env -> add_sequence env "known" "KNOWN:SpectecTerminals" seq_typ
    |> fun env -> add_nat env "count" "COUNT:Nat"
    |> fun env -> add_nat env "width" "WIDTH:Nat"
  in
  assert_active_invalid
    "unbound-invalid-concatn"
    concatn_ctx concatn_env
    [ "KNOWN:SpectecTerminals"; "COUNT:Nat"; "WIDTH:Nat" ]
    (equality concatn known)

let implemented_inverse name input_typ result_typ =
  let input = var "input" input_typ in
  let clause =
    DefD
      ( [ param "input" input_typ ]
      , [ arg input ]
      , NumE (`Nat Z.zero) $$ region % result_typ
      , [] )
    $ region
  in
  DecD (id name, [ param "input" input_typ ], result_typ, [ clause ]) $ region

let test_blocked_concatn_rolls_back_helper () =
  let count = var "count" nat_typ in
  let source_typ = IterT (nat_typ, ListN (count, None)) $ region in
  let script =
    [ declaration "rollback_bytes" [ param "element" nat_typ ] seq_typ
    ; implemented_inverse "rollback_inverse_bytes" seq_typ nat_typ
    ; inverse_hint "rollback_bytes" "rollback_inverse_bytes"
    ; declaration "rollback_concatn"
        [ param "chunks" nested_typ; param "width" nat_typ ] seq_typ
    ; declaration "rollback_outer_inverse"
        [ param "width" nat_typ; param "result" seq_typ ] nested_typ
    ; inverse_hint "rollback_concatn" "rollback_outer_inverse"
    ]
  in
  let ctx = context script in
  let call = concatn_call "rollback_concatn" "rollback_bytes" source_typ in
  let known = var "known" seq_typ in
  let env =
    Expr_env.empty
    |> fun env -> add_sequence env "known" "KNOWN:SpectecTerminals" seq_typ
    |> fun env -> add_nat env "count" "COUNT:Nat"
    |> fun env -> add_nat env "width" "WIDTH:Nat"
  in
  let premise = IfPr (equality call known) $ region in
  (match
     Premise_translate.translate_premise
       ctx env
       ~bound_vars:[ "KNOWN:SpectecTerminals"; "COUNT:Nat"; "WIDTH:Nat" ]
       (origin "blocked-concatn-rollback") premise
   with
  | Premise_result.Blocked diagnostics
    when List.exists Diagnostics.is_fatal diagnostics -> ()
  | Blocked _ -> failwith "blocked concatn reconstruction was not fatal"
  | Deferred _ -> failwith "blocked concatn reconstruction was deferred"
  | Complete _ -> failwith "unimplemented outer inverse unexpectedly completed");
  assert_no_inverse_helper "blocked-concatn-rollback" ctx

let () =
  test_unique_omission ();
  test_absolute_omission_after_type_parameter ();
  test_ambiguous_omission ();
  test_missing_omission ();
  test_bound_pair_falls_back ();
  test_bound_concatn_falls_back ();
  test_unbound_invalid_demands_stay_fatal ();
  test_blocked_concatn_rolls_back_helper ()
