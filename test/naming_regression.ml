open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id text = text $ region
let nat_typ = NumT `NatT $ region
let var text = VarE (id text) $$ region % nat_typ
let exp_param text = ExpP (id text, nat_typ) $ region
let exp_arg exp = ExpA exp $ region
let origin name = Origin.synthetic ~ast_constructor:"NamingRegression" name

let atom text =
  Xl.Atom.Atom text $$ region % Xl.Atom.info "naming-regression"

let definition name rhs =
  let parameter = exp_param "value" in
  let value = var "value" in
  let clause = DefD ([ parameter ], [ exp_arg value ], rhs value, []) $ region in
  DecD (id name, [ parameter ], nat_typ, [ clause ]) $ region

let builtin_hint name =
  let hint =
    { hintid = id "builtin"
    ; hintexp = El.Ast.BoolE true $ region
    }
  in
  HintD (DecH (id name, [ hint ]) $ region) $ region

let declaration name =
  DecD (id name, [ exp_param "value" ], nat_typ, []) $ region

let expect label expected actual =
  if actual <> expected then
    failwith (Printf.sprintf "%s: expected %S, got %S" label expected actual)

let contains text fragment =
  let rec search index =
    index + String.length fragment <= String.length text
    && (String.sub text index (String.length fragment) = fragment
        || search (index + 1))
  in
  fragment = "" || search 0

let assert_readable name =
  let forbidden = [ "_"; "x5f"; "loc-" ] in
  forbidden
  |> List.iter (fun fragment ->
    if contains (String.lowercase_ascii name) fragment then
      failwith (Printf.sprintf "visible prefix name %S contains %S" name fragment))

let test_local_names () =
  let names =
    Local_name.empty
    |> fun names -> Local_name.reserve_sources names [ "result1"; "pattern1" ]
  in
  let typed role names =
    Local_name.fresh_qualified_name names role (sort_ref (sort "Nat"))
  in
  let result, names = typed Local_name.Result names in
  let pattern, names = typed Local_name.Pattern names in
  let result_next, names = typed Local_name.Result names in
  let head, names = typed Local_name.Head names in
  let tail, _ = typed Local_name.Tail names in
  expect "reserved result" "RESULT2:Nat" result;
  expect "reserved pattern" "PATTERN2:Nat" pattern;
  expect "independent result counter" "RESULT3:Nat" result_next;
  expect "independent head counter" "HEAD1:Nat" head;
  expect "independent tail counter" "TAIL1:Nat" tail;
  let typed_result, _ =
    Local_name.fresh_typed Local_name.empty Local_name.Result (sort "Nat")
  in
  if typed_result <> Var "RESULT1:Nat" then
    failwith "local typed result was not emitted inline";
  let names =
    Local_name.reserve_existing_many Local_name.empty [ "RESULT1:Nat" ]
  in
  let result, _ = typed Local_name.Result names in
  expect "typed existing variable reservation" "RESULT2:Nat" result;
  if
    Local_name.reserve_sources Local_name.empty [ "source_value" ]
    |> fun names ->
    Local_name.source_qualified names "source_value" (sort_ref (sort "Nat"))
    <> Var "SOURCE_VALUE:Nat"
  then failwith "source binder did not retain readable source spelling and sort";
  let names =
    Local_name.reserve_sources Local_name.empty [ "value-name"; "value.name" ]
  in
  let source_name source =
    Local_name.source_qualified_name names source (sort_ref (sort "Nat"))
  in
  expect "first lossy source binder" "VALUE_NAME:Nat"
    (source_name "value-name");
  expect "second lossy source binder" "VALUE_NAME2:Nat"
    (source_name "value.name");
  expect "repeated raw source binder" "VALUE_NAME:Nat"
    (source_name "value-name");
  expect "source star identity" "VALUE_STAR" (Naming.source_var "value*");
  expect "source prime identity" "VALUE_PRIME" (Naming.source_var "value'");
  expect "non-source helper spelling unchanged" "VALUE" (Naming.maude_var "value*");
  let names =
    Local_name.reserve_sources Local_name.empty
      [ "head1"; "tail1"; "output1"; "witness1"; "chunk1" ]
  in
  let head, names = typed Local_name.Head names in
  let tail, names = typed Local_name.Tail names in
  let output, names = typed Local_name.Output names in
  let witness, names = typed Local_name.Witness names in
  let chunk, _ = typed Local_name.Chunk names in
  expect "reserved helper head" "HEAD2:Nat" head;
  expect "reserved helper tail" "TAIL2:Nat" tail;
  expect "reserved helper output" "OUTPUT2:Nat" output;
  expect "reserved helper witness" "WITNESS2:Nat" witness;
  expect "reserved helper chunk" "CHUNK2:Nat" chunk;
  (match
     Local_name.source_qualified_name
       Local_name.empty "missing" (sort_ref (sort "Nat"))
   with
  | _ -> failwith "unreserved source lookup silently reconstructed a name"
  | exception Invalid_argument _ -> ())

let test_nested_and_phantom_name_collisions () =
  let names =
    Local_name.empty
    |> fun names -> Local_name.reserve_sources names [ "typ_value" ]
    |> fun names -> Local_name.reserve_phantom names "value"
  in
  expect "phantom avoids source binder"
    "TYP_VALUE2:SpectecType"
    (Local_name.phantom_qualified_name
       names "value" (sort_ref (sort "SpectecType")));
  let static_env : Type_static_env.static_env =
    Type_static_env.add_exp Type_static_env.empty "outer"
      { static_term = Var "SOURCE_VALUE:Nat"
      ; static_sort = sort "Nat"
      ; static_typ = nat_typ
      }
  in
  let nested_names =
    Type_static_env.reserve_static_env Local_name.empty static_env
    |> fun names -> Local_name.reserve_sources names [ "source_value" ]
  in
  expect "nested static environment reservation"
    "SOURCE_VALUE2:Nat"
    (Local_name.source_qualified_name
       nested_names "source_value" (sort_ref (sort "Nat")))

let has_qualified_var_declaration statements =
  statements
  |> List.exists (fun statement ->
    match statement.node with
    | VarDecl { name; _ } -> String.contains name ':'
    | _ -> false)

let test_helper_local_names () =
  let binding : Expr_env.binding =
    { term = Var "CALLER:Nat"; sort = sort "Nat"; typ = nat_typ }
  in
  let names =
    Local_name.reserve_sources Local_name.empty [ "capture_value" ]
  in
  let captures =
    [ { Helper_request.source_id = "capture_value"
      ; call_term = binding.term
      ; formal_var =
          Local_name.source_qualified_name
            names "capture_value" (sort_ref binding.sort)
      ; sort = binding.sort
      ; typ = binding.typ
      }
    ]
  in
  (match captures with
  | [ capture ] ->
    expect "source capture formal" "CAPTURE_VALUE:Nat" capture.formal_var
  | _ -> failwith "source capture allocation changed capture cardinality");
  let element_sort = sort "Nat" in
  let head_var, names =
    Local_name.fresh_qualified_name
      Local_name.empty Local_name.Head (sort_ref element_sort)
  in
  let tail_var, names =
    Local_name.fresh_qualified_name
      names Local_name.Tail (sort_ref (sort "SpectecTerminals"))
  in
  let witness_var, _ =
    Local_name.fresh_qualified_name
      names Local_name.Witness (sort_ref element_sort)
  in
  let request =
    { Helper_request.kind =
        Helper_request.Membership_witness
          { Membership_witness_helper.source = "item <- items"
          ; element_sort
          ; head_var
          ; tail_var
          ; witness_var
          }
    ; reason = "naming regression"
    ; origin = origin "path-derived-helper-local-must-not-escape"
    }
  in
  let helpers = Helper.create () in
  ignore (Helper.request helpers request);
  let statements = Helper.materialize_static helpers in
  if has_qualified_var_declaration statements then
    failwith "inline helper local retained a redundant VarDecl";
  let rendered =
    statements
    |> List.map Emit.render_generated
    |> String.concat "\n"
  in
  List.iter
    (fun expected ->
      if not (contains rendered expected) then
        failwith ("materialized helper omitted local " ^ expected))
    [ "HEAD1:Nat"; "TAIL1:SpectecTerminals"; "WITNESS1:Nat" ]

let test_captured_helper_materializer_declarations () =
  let capture : Helper_request.capture =
    { source_id = "captured"
    ; call_term = Var "CALLER:Nat"
    ; formal_var = "CAPTURED:Nat"
    ; sort = sort "Nat"
    ; typ = nat_typ
    }
  in
  let source_shape : Helper_request.iter_map_source_shape =
    { iter_source = "captured helper"
    ; body_source = "captured"
    ; source_source = "items"
    ; output_typ_source = "nat"
    ; source_typ_source = "nat*"
    }
  in
  let iter_map : Helper_request.iter_map =
    { source_shape
    ; call_shape = Source_then_captures
    ; generator_var = "ITEM:Nat"
    ; helper_head_var = "HEAD1:Nat"
    ; source_tail_var = "TAIL1:SpectecTerminals"
    ; body_result_var = "OUTPUT1:Nat"
    ; source_item_shape = Source_flat_terminal
    ; output_item_shape = Output_flat_terminal
    ; source_element_sort = sort "Nat"
    ; captures = [ capture ]
    ; lowered_body = Var "CAPTURED:Nat"
    ; body_eq_conditions = []
    }
  in
  let iter_request =
    { Helper_request.kind = Iter_map iter_map
    ; reason = "captured iter declaration regression"
    ; origin = origin "captured-iter"
    }
  in
  let iter_entry : Helper_registry.entry =
    { name = "helper.test.captured-iter"; request = iter_request }
  in
  let iter_statements =
    Helper_materialize_iter.materialize_iter_map iter_entry iter_map
  in
  if has_qualified_var_declaration iter_statements then
    failwith "captured iter materializer constructed a qualified VarDecl";
  let inverse : Helper_request.optional_map_inverse =
    { source_shape
    ; generator_var = "ITEM:Nat"
    ; helper_head_var = "HEAD1:Nat"
    ; source_element_sort = sort "Nat"
    ; captures = [ capture ]
    ; lowered_body = App ("some", [ Var "CAPTURED:Nat" ])
    ; body_eq_conditions = []
    }
  in
  let inverse_request =
    { Helper_request.kind = Optional_map_inverse inverse
    ; reason = "captured inverse declaration regression"
    ; origin = origin "captured-inverse"
    }
  in
  let inverse_entry : Helper_registry.entry =
    { name = "helper.test.captured-inverse"; request = inverse_request }
  in
  let inverse_statements =
    Helper_materialize_inverse.materialize_optional_map_inverse
      inverse_entry inverse
  in
  if has_qualified_var_declaration inverse_statements then
    failwith "captured inverse materializer constructed a qualified VarDecl"

let rec term_contains op_name = function
  | Var _ | Const _ | Qid _ -> false
  | App (name, args) ->
    name = op_name || List.exists (term_contains op_name) args

let rec term_vars = function
  | Var name -> [ name ]
  | Const _ | Qid _ -> []
  | App (_, args) -> List.concat_map term_vars args

let statement_calls lhs_op called_op statement =
  match statement.node with
  | Eq (App (name, _), rhs, _)
  | Ceq (App (name, _), rhs, _, _)
    when name = lhs_op -> term_contains called_op rhs
  | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _
  | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ -> false

let context script =
  let index = Analysis.Source_index.of_script script in
  let builtins = Builtin_registry.of_source_index index in
  Context.create index builtins

let test_pattern_local_names () =
  let pair_typ = TupT [ id "left", nat_typ; id "right", nat_typ ] $ region in
  let pattern = TupE [ var "pattern1"; var "_" ] $$ region % pair_typ in
  let result, names =
    Expr_translate.lower_pattern_with_bindings_named
      Local_name.empty (context []) Expr_env.empty
      (origin "pattern-local") pattern
  in
  let vars = Option.fold ~none:[] ~some:term_vars result.pattern_term in
  if not (List.mem "PATTERN1:Nat" vars) then
    failwith "source pattern variable spelling was not preserved";
  if not (List.mem "PATTERN2:Nat" vars) then
    failwith "wildcard did not avoid the reserved source PATTERN1 name";
  let next, _ =
    Local_name.fresh_qualified_name
      names Local_name.Pattern (sort_ref (sort "Nat"))
  in
  expect "pattern supply continuation" "PATTERN3:Nat" next;
  vars
  |> List.iter (fun name ->
    let lower = String.lowercase_ascii name in
    if
      contains lower "loc-" || contains lower "pattern-wild"
      || contains lower "pattern-iter"
    then failwith ("path/location-derived pattern variable remains: " ^ name))

let test_pattern_supply_threads_and_rolls_back () =
  let ctx = context [] in
  let wildcard = var "_" in
  let first, names =
    Expr_translate.lower_pattern_with_bindings_named
      Local_name.empty ctx Expr_env.empty (origin "first") wildcard
  in
  let second, _ =
    Expr_translate.lower_pattern_with_bindings_named
      names ctx Expr_env.empty (origin "second") wildcard
  in
  if first.pattern_term <> Some (Var "PATTERN1:Nat") then
    failwith "first statement-local wildcard did not use PATTERN1";
  if second.pattern_term <> Some (Var "PATTERN2:Nat") then
    failwith "multi-pattern statement reset the Local_name supply";
  let missing_call =
    CallE (id "missing", []) $$ region % nat_typ
  in
  let prem = LetPr ([], wildcard, missing_call) $ region in
  let outcome, names =
    Premise_translate.translate_premise_named
      Local_name.empty ctx Expr_env.empty ~bound_vars:[]
      (origin "rollback") prem
  in
  (match outcome with
  | Premise_result.Complete _ ->
    failwith "fatal LetPr unexpectedly completed"
  | Blocked _ | Deferred _ -> ());
  let next, _ =
    Local_name.fresh_qualified_name
      names Local_name.Pattern (sort_ref (sort "Nat"))
  in
  expect "blocked stage supply rollback" "PATTERN1:Nat" next

let test_iter_premise_threads_supply () =
  let ctx = context [] in
  let seq_typ = IterT (nat_typ, List) $ region in
  let source = VarE (id "values") $$ region % seq_typ in
  let env =
    Expr_env.add Expr_env.empty "values"
      { term = Var "VALUES"
      ; sort = sort "SpectecTerminals"
      ; typ = seq_typ
      }
  in
  let body = IfPr (BoolE true $$ region % (BoolT $ region)) $ region in
  let iterexp = List, [ id "value", source ] in
  let prem = IterPr (body, iterexp) $ region in
  let _, names =
    Premise_iter.lower
      Local_name.empty
      ~lower_body:(fun names _ctx env ~bound_vars _origin _prem ->
        let _, names =
          Local_name.fresh_qualified_name
            names Local_name.Result (sort_ref (sort "Nat"))
        in
        Premise_result.empty_with_env ~bound_vars env, names)
      ~discharge_static_validation:false
      ctx env ~bound_vars:[ "VALUES" ] ~future_prems:[]
      ~escape_source_ids:[] (origin "iter-supply") ~prem ~body iterexp
  in
  let next, _ =
    Local_name.fresh_qualified_name
      names Local_name.Result (sort_ref (sort "Nat"))
  in
  expect "IterPr callback supply propagation" "RESULT2:Nat" next

let test_variable_sort_collision () =
  let origin = origin "variable-sort-collision" in
  let statements =
    [ generated ~origin (Maude_ir.var "RESULT1" (sort_ref (sort "Nat")))
    ; generated ~origin (Maude_ir.var "RESULT1" (sort_ref (sort "Int")))
    ]
  in
  let _, violations = Maude_registry.build statements in
  if
    not
      (List.exists
         (fun violation ->
           violation.Maude_registry.constructor =
             "MaudeRegistry/variable-sort-collision")
         violations)
  then failwith "same Maude variable at conflicting sorts passed silently"

let test_operator_identity_uses_structural_equality () =
  let seen = Hashtbl.create 32_771 in
  let rec find_collision index =
    if index > 300_000 then
      failwith "could not construct an operator identity hash collision"
    else
      let term = Const ("structural-id-" ^ string_of_int index) in
      let hash = Hashtbl.hash term in
      match Hashtbl.find_opt seen hash with
      | Some previous when previous <> term -> previous, term
      | _ ->
        Hashtbl.replace seen hash term;
        find_collision (index + 1)
  in
  let left, right = find_collision 0 in
  let origin = origin "operator-identity-structural-equality" in
  let statements =
    [ generated ~origin
        (op "structural-id-test" [] (sort "Nat") ~attrs:[ Id left ])
    ; generated ~origin
        (op "structural-id-test" [] (sort "Nat") ~attrs:[ Id right ])
    ]
  in
  let _, violations = Maude_registry.build statements in
  if
    not
      (List.exists
         (fun violation ->
           violation.Maude_registry.constructor =
             "MaudeRegistry/op/duplicate-incompatible")
         violations)
  then failwith "distinct operator identity terms were equated by hash"

let test_inline_source_variable_scope () =
  let origin = origin "inline-source-variable-scope" in
  let generated node = generated ~origin node in
  let separate =
    [ generated (eq (Var "SOURCE:Nat") (Const "0"))
    ; generated (eq (Var "SOURCE:Int") (Const "0"))
    ]
  in
  let _, separate_violations = Maude_registry.build separate in
  if
    List.exists
      (fun violation ->
        violation.Maude_registry.constructor =
          "MaudeRegistry/variable-sort-collision")
      separate_violations
  then failwith "same readable source binder was rejected across statements";
  let conflicting =
    [ generated (eq (Var "SOURCE:Nat") (Var "SOURCE:Int")) ]
  in
  let _, conflicting_violations = Maude_registry.build conflicting in
  if
    not
      (List.exists
         (fun violation ->
           violation.Maude_registry.constructor =
             "MaudeRegistry/variable-sort-collision")
         conflicting_violations)
  then failwith "conflicting inline source binder sorts passed within one statement"

let test_readable_prefix_names () =
  let names =
    [ Naming.definition_op (id "source__name_")
    ; Naming.builtin_definition_op (id "source__name_")
    ; Naming.relation_op (id "source__name_")
    ; Naming.specialized_definition_op
        (id "source__name_") [ "target__one_"; "target'two" ]
    ; Naming.specialized_definition_op ~builtin:true
        (id "source__name_") [ "target__one_" ]
    ]
  in
  expect "ordinary definition" "def.source-name" (List.nth names 0);
  expect "builtin definition" "builtin.source-name" (List.nth names 1);
  expect "relation" "rel.source-name" (List.nth names 2);
  expect "specialization"
    "def.source-name.with.target-one.target-two" (List.nth names 3);
  expect "builtin specialization"
    "builtin.source-name.with.target-one" (List.nth names 4);
  List.iter assert_readable names

let test_builtin_declaration_and_call () =
  let builtin_name = "backend_value_" in
  let caller_name = "call_backend_" in
  let builtin = definition builtin_name Fun.id in
  let caller =
    definition caller_name (fun value ->
      CallE (id builtin_name, [ exp_arg value ]) $$ region % nat_typ)
  in
  let script = [ builtin; builtin_hint builtin_name; caller ] in
  let ctx = context script in
  let builtin_op = Context.definition_op ctx (id builtin_name) in
  let caller_op = Context.definition_op ctx (id caller_name) in
  expect "hint builtin namespace" "builtin.backend-value" builtin_op;
  expect "ordinary namespace" "def.call-backend" caller_op;
  let result = Driver.translate script in
  let declarations =
    result.module_.statements
    |> List.filter_map (fun statement ->
      match statement.node with
      | OpDecl declaration -> Some declaration.name
      | _ -> None)
  in
  if not (List.mem builtin_op declarations) then
    failwith "hint(builtin) DecD declaration did not use builtin namespace";
  if
    not
      (List.exists
         (statement_calls caller_op builtin_op)
         result.module_.statements)
  then
    failwith "CallE did not use the builtin DecD operator";
  let rendered = Emit.render_module result.module_ in
  if not (contains rendered "VALUE:Nat") then
    failwith "DefD source binder was not emitted inline-qualified";
  if contains rendered "_CLAUSE_" then
    failwith "DefD clause-derived binder seed remains in generated output"

let test_typd_source_binder () =
  let source = exp_param "source_value" in
  let alias = AliasT nat_typ $ region in
  let inst = InstD ([], [], alias) $ region in
  let typd = TypD (id "binder_family", [ source ], [ inst ]) $ region in
  let rendered = Driver.translate [ typd ] |> fun result -> Emit.render_module result.module_ in
  if not (contains rendered "SOURCE_VALUE:Nat") then
    failwith "TypD source binder was not emitted inline-qualified";
  if contains rendered "SCRIPT_" then
    failwith "TypD path-derived binder seed remains in generated output"

let test_constructor_component_occurrences () =
  let pair_typ =
    TupT [ id "item", nat_typ; id "item", nat_typ ] $ region
  in
  let mixop =
    Xl.Mixop.Seq
      [ Xl.Mixop.Atom (atom "PAIR")
      ; Xl.Mixop.Arg ()
      ; Xl.Mixop.Atom (atom "WITH")
      ; Xl.Mixop.Arg ()
      ]
  in
  let typcase = mixop, (pair_typ, [], []), [] in
  let variant = VariantT [ typcase ] $ region in
  let inst = InstD ([], [], variant) $ region in
  let typd = TypD (id "pair_family", [], [ inst ]) $ region in
  let constructor =
    Naming.constructor_op_in_category "pair_family" mixop
  in
  let result = Driver.translate [ typd ] in
  let variables =
    result.module_.statements
    |> List.find_map (fun statement ->
      match statement.node with
      | Cmb (App (name, [ Var left; Var right ]), _, _)
        when name = constructor ->
        Some (left, right)
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _
      | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ -> None)
  in
  match variables with
  | Some ("ITEM:Nat", "ITEM2:Nat") -> ()
  | Some (left, right) ->
    failwith
      (Printf.sprintf
         "constructor component occurrences were not named independently: %S, %S"
         left right)
  | None -> failwith "repeated-component constructor membership was not emitted"

let constructor_entry
    ?static_args_key
    ?payload_labels
    ?(category = "family")
    ?(constructor_op = "family.token")
    ~origin ~mixop ~arity ~witnesses ~sorts () =
  let payload_labels =
    Option.value payload_labels
      ~default:(List.init arity (fun _ -> Constructor_registry.Structural_payload))
  in
  { Constructor_registry.source_category = category
  ; declaring_category = category
  ; static_args_key
  ; mixop
  ; arity
  ; constructor_op
  ; projection_ops =
      List.init arity (Naming.projection_op constructor_op)
  ; payload_labels
  ; payload_witnesses = witnesses
  ; payload_sorts = sorts
  ; origin
  ; enclosing = []
  ; status = Constructor_registry.Emitted
  ; construction_domain = Constructor_registry.Total_constructor
  }

let test_constructor_surface_resolution () =
  let registry = Constructor_registry.create () in
  let token = atom "DIV" in
  let nullary_mixop = Xl.Mixop.Atom token in
  let unary_mixop =
    Xl.Mixop.Seq [ Xl.Mixop.Atom token; Xl.Mixop.Arg () ]
  in
  Constructor_registry.register registry
    (constructor_entry
       ~category:"binop" ~constructor_op:"binop.div"
       ~origin:(origin "nullary") ~mixop:nullary_mixop ~arity:0
       ~witnesses:[] ~sorts:[] ());
  Constructor_registry.register registry
    (constructor_entry
       ~category:"binop" ~constructor_op:"binop.div"
       ~payload_labels:[ Constructor_registry.Source_category "sx" ]
       ~origin:(origin "unary") ~mixop:unary_mixop ~arity:1
       ~witnesses:[ Const "unrelated-rendered-witness" ]
       ~sorts:[ sort "SpectecTerminal" ] ());
  Constructor_registry.resolve_surfaces registry;
  let entry arity =
    Constructor_registry.entries registry
    |> List.find (fun entry -> entry.Constructor_registry.arity = arity)
  in
  expect "nullary constructor surface" "binop.div" (entry 0).constructor_op;
  expect "unary constructor surface" "binop.div-sx" (entry 1).constructor_op;
  expect "resolved projection" "proj.binop.div-sx.0"
    (List.hd (entry 1).projection_ops);
  List.iter
    (fun entry -> assert_readable entry.Constructor_registry.constructor_op)
    (Constructor_registry.entries registry)

let test_constructor_lossy_collision () =
  let registry = Constructor_registry.create () in
  let mixop text = Xl.Mixop.Atom (atom text) in
  Constructor_registry.register registry
    (constructor_entry
       ~origin:(origin "underscore-owner") ~mixop:(mixop "SAME_TOKEN")
       ~arity:0 ~witnesses:[] ~sorts:[] ());
  Constructor_registry.register registry
    (constructor_entry
       ~origin:(origin "apostrophe-owner") ~mixop:(mixop "SAME'TOKEN")
       ~arity:0 ~witnesses:[] ~sorts:[] ());
  Constructor_registry.resolve_surfaces registry;
  if
    not
      (Constructor_registry.diagnostics ~profile:"naming-regression" registry
       |> List.exists (fun diagnostic ->
         diagnostic.Diagnostics.constructor =
           "Unsupported/NamingCollision/constructor"))
  then
    failwith "lossy same-signature constructor collision was not rejected"

let test_constructor_static_key_sharing () =
  let registry = Constructor_registry.create () in
  let mixop = Xl.Mixop.Seq [ Xl.Mixop.Atom (atom "TOKEN"); Xl.Mixop.Arg () ] in
  let entry key name =
    constructor_entry
      ~static_args_key:key
      ~origin:(origin name) ~mixop ~arity:1
      ~witnesses:[ Const "opaque-witness" ]
      ~sorts:[ sort "SpectecTerminal" ] ()
  in
  Constructor_registry.register registry (entry "left" "static-left");
  Constructor_registry.register registry (entry "right" "static-right");
  Constructor_registry.resolve_surfaces registry;
  let entries = Constructor_registry.entries registry in
  if List.length entries <> 2 then
    failwith "static-contextual source entries were merged in the registry";
  if not (List.for_all (fun entry -> entry.Constructor_registry.constructor_op = "family.token") entries)
  then failwith "same-arity static-contextual constructors did not share their surface";
  if
    Constructor_registry.diagnostics ~profile:"naming-regression" registry
    |> List.exists (fun diagnostic ->
      diagnostic.Diagnostics.constructor = "Unsupported/NamingCollision/constructor")
  then failwith "static-contextual sharing was reported as a visible collision"

let test_constructor_registry_sealing () =
  let registry = Constructor_registry.create () in
  let first =
    constructor_entry
      ~origin:(origin "first") ~mixop:(Xl.Mixop.Atom (atom "FIRST"))
      ~arity:0 ~witnesses:[] ~sorts:[] ()
  in
  Constructor_registry.register registry first;
  Constructor_registry.resolve_surfaces registry;
  (match Constructor_registry.register_checked registry first with
  | Constructor_registry.Already_registered -> ()
  | Constructor_registry.Registered
  | Constructor_registry.Rejected_after_resolution ->
    failwith "exact post-resolution registration was not accepted");
  let late =
    constructor_entry
      ~constructor_op:"family.late"
      ~origin:(origin "late") ~mixop:(Xl.Mixop.Atom (atom "LATE"))
      ~arity:0 ~witnesses:[] ~sorts:[] ()
  in
  (match Constructor_registry.register_checked registry late with
  | Constructor_registry.Rejected_after_resolution -> ()
  | Constructor_registry.Registered
  | Constructor_registry.Already_registered ->
    failwith "new post-resolution registration was not rejected");
  if List.length (Constructor_registry.entries registry) <> 1 then
    failwith "rejected late constructor was inserted";
  if
    not
      (Constructor_registry.diagnostics ~profile:"naming-regression" registry
       |> List.exists (fun diagnostic ->
         diagnostic.Diagnostics.constructor =
           "ConstructorRegistry/late-registration"))
  then failwith "late constructor rejection lacked a registry diagnostic"

let test_ordinary_catalog_spelling_is_not_builtin () =
  let source_id = "inv_concat_" in
  let script = [ declaration source_id ] in
  let ctx = context script in
  expect "ordinary catalog spelling" "def.inv-concat"
    (Context.definition_op ctx (id source_id));
  if Builtin_registry.declaration_is_partial (Context.builtins ctx) source_id then
    failwith "ordinary inv_concat_ became partial from backend catalog spelling";
  let result = Driver.translate script in
  let declaration =
    result.module_.statements
    |> List.find_map (fun statement ->
      match statement.node with
      | OpDecl declaration when declaration.name = "def.inv-concat" ->
        Some declaration
      | SortDecl _ | SubsortDecl _ | OpDecl _ | VarDecl _
      | Mb _ | Cmb _ | Eq _ | Ceq _ | Rl _ | Crl _ -> None)
    |> Option.get
  in
  if declaration.kind <> Total then
    failwith "ordinary inv_concat_ declaration became partial"

let test_namespace_and_collision_policy () =
  let ordinary = definition "shared_name" Fun.id in
  let builtin = definition "shared'name" Fun.id in
  let distinct = [ ordinary; builtin; builtin_hint "shared'name" ] in
  let distinct_result = Driver.translate distinct in
  if
    List.exists
      (fun diagnostic ->
        diagnostic.Diagnostics.constructor =
          "Unsupported/NamingCollision/definition")
      distinct_result.diagnostics
  then
    failwith "ordinary and builtin namespaces were treated as a collision";
  let collision =
    Driver.translate
      [ definition "lossy_name" Fun.id
      ; definition "lossy'name" Fun.id
      ]
  in
  if
    not
      (List.exists
         (fun diagnostic ->
           diagnostic.Diagnostics.constructor =
             "Unsupported/NamingCollision/definition")
         collision.diagnostics)
  then
    failwith "same-candidate same-domain source definitions did not collide"

let relation name =
  RelD (id name, [], Xl.Mixop.Atom (atom "REL"), nat_typ, []) $ region

let record_type name =
  let deftyp = StructT [] $ region in
  TypD (id name, [], [ InstD ([], [], deftyp) $ region ]) $ region

let execution_mixop =
  let marker = Xl.Atom.SqArrow $$ region % Xl.Atom.info "naming-regression" in
  Xl.Mixop.Infix (Xl.Mixop.Arg (), marker, Xl.Mixop.Arg ())

let execution_relation name =
  let typ = TupT [ id "input", nat_typ; id "output", nat_typ ] $ region in
  RelD (id name, [], execution_mixop, typ, []) $ region

let rewrite_definition name =
  let seq_typ = IterT (nat_typ, List) $ region in
  let values = VarE (id "values") $$ region % seq_typ in
  let item = var "item" in
  let condition = MemE (item, values) $$ region % (BoolT $ region) in
  let clause =
    DefD
      ([ exp_param "item" ], [ exp_arg values ], item,
       [ IfPr condition $ region ])
    $ region
  in
  DecD (id name, [ ExpP (id "values", seq_typ) $ region ], nat_typ, [ clause ])
  $ region

let test_relation_and_record_collisions () =
  let result =
    Driver.translate
      [ relation "surface_name"
      ; relation "surface'name"
      ; record_type "record_name"
      ; record_type "record'name"
      ]
  in
  let has constructor =
    List.exists
      (fun diagnostic -> diagnostic.Diagnostics.constructor = constructor)
      result.diagnostics
  in
  if not (has "Unsupported/NamingCollision/relation") then
    failwith "lossy relation surface collision was not rejected";
  if not (has "Unsupported/NamingCollision/record-constructor") then
    failwith "lossy record constructor collision was not rejected";
  let repeated = Driver.translate [ relation "repeat_name"; relation "repeat_name" ] in
  if
    List.exists
      (fun diagnostic ->
        diagnostic.Diagnostics.constructor = "Unsupported/NamingCollision/relation")
      repeated.diagnostics
  then failwith "repeated identical relation owner was rejected"

let test_context_builtin_cache_refresh () =
  let name = "cache_name_" in
  let script = [ declaration name ] in
  let ctx = context script in
  let ordinary = Naming.definition_op (id name) in
  let builtin = Naming.builtin_definition_op (id name) in
  if not (Context.emitted_definition_operator ctx ordinary) then
    failwith "initial ordinary definition surface was absent from context cache";
  let hinted_index = Analysis.Source_index.of_script [ declaration name; builtin_hint name ] in
  let rebuilt =
    Context.with_builtins ctx (Builtin_registry.of_source_index hinted_index)
  in
  if Context.emitted_definition_operator rebuilt ordinary then
    failwith "with_builtins retained the stale ordinary definition surface";
  if not (Context.emitted_definition_operator rebuilt builtin) then
    failwith "with_builtins did not rebuild the builtin definition surface"

let test_configuration_sort_names_and_collisions () =
  let def_sort = Naming.definition_config_sort (id "config_name'") [] in
  let rel_sort = Naming.relation_config_sort (id "config_relation'") in
  expect "definition config sort" "DecConfConfigName" def_sort;
  expect "relation config sort" "RelConfConfigRelation" rel_sort;
  List.iter assert_readable [ def_sort; rel_sort ];
  let result =
    Driver.translate
      [ rewrite_definition "config_name"
      ; rewrite_definition "config'name"
      ; execution_relation "config_relation"
      ; execution_relation "config'relation"
      ]
  in
  let has constructor =
    List.exists
      (fun diagnostic -> diagnostic.Diagnostics.constructor = constructor)
      result.diagnostics
  in
  if not (has "Unsupported/NamingCollision/definition-config-sort") then
    failwith "lossy rewrite definition config sort collision was not rejected";
  if not (has "Unsupported/NamingCollision/relation-config-sort") then
    failwith "lossy relation config sort collision was not rejected"

let () =
  test_local_names ();
  test_nested_and_phantom_name_collisions ();
  test_helper_local_names ();
  test_captured_helper_materializer_declarations ();
  test_pattern_local_names ();
  test_pattern_supply_threads_and_rolls_back ();
  test_iter_premise_threads_supply ();
  test_variable_sort_collision ();
  test_operator_identity_uses_structural_equality ();
  test_inline_source_variable_scope ();
  test_readable_prefix_names ();
  test_builtin_declaration_and_call ();
  test_typd_source_binder ();
  test_constructor_component_occurrences ();
  test_constructor_surface_resolution ();
  test_constructor_lossy_collision ();
  test_constructor_static_key_sharing ();
  test_constructor_registry_sealing ();
  test_ordinary_catalog_spelling_is_not_builtin ();
  test_namespace_and_collision_policy ();
  test_relation_and_record_collisions ();
  test_context_builtin_cache_refresh ();
  test_configuration_sort_names_and_collisions ()
