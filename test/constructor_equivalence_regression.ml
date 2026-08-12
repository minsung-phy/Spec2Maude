open Il.Ast
open Translator
open Maude_ir
open Util.Source

let region = no_region
let id name = name $ region
let nat_typ = NumT `NatT $ region
let int_typ = NumT `IntT $ region
let bool_typ = BoolT $ region
let category_typ name = VarT (id name, []) $ region
let nat value = NumE (`Nat (Z.of_int value)) $$ region % nat_typ

let atom name =
  Xl.Atom.Atom name $$ region % Xl.Atom.info "representation-sharing"

let mixop name =
  Xl.Mixop.Seq [ Xl.Mixop.Atom (atom name); Xl.Mixop.Arg () ]

let typcase ?(binds = []) ?(prems = []) payload mixop =
  mixop, (payload, binds, prems), []

let variant name cases =
  TypD (id name, [], [ InstD ([], [], VariantT cases $ region) $ region ]) $ region

let parameterized_variant name case_mixop =
  let parameter = ExpP (id "limit", nat_typ) $ region in
  let argument = ExpA (nat 1) $ region in
  let body = VariantT [ typcase nat_typ case_mixop ] $ region in
  TypD (id name, [ parameter ], [ InstD ([], [ argument ], body) $ region ]) $ region

let typed_var typ name = VarE (id name) $$ region % typ

let sube source_typ target_typ =
  SubE (typed_var source_typ "seed", source_typ, target_typ)
  $$ region % target_typ

let coercion name source_typ target_typ exp =
  let parameter = ExpP (id "seed", source_typ) $ region in
  let clause =
    DefD ([], [ ExpA (typed_var source_typ "seed") $ region ], exp, []) $ region
  in
  DecD (id name, [ parameter ], target_typ, [ clause ]) $ region

let translate ?(allow_fatal = false) script =
  let source_index = Analysis.Source_index.of_script script in
  let ctx = Context.create source_index (Builtin_registry.of_source_index source_index) in
  let output = Def_translate.translate_script ctx script in
  if not allow_fatal && List.exists Diagnostics.is_fatal output.diagnostics then
    failwith (Diagnostics.render_all output.diagnostics);
  source_index, ctx, output

let entry ctx category case_mixop =
  Constructor_registry.entries (Context.constructors ctx)
  |> List.find (fun entry ->
    entry.Constructor_registry.source_category = category
    && Il.Eq.eq_mixop entry.mixop case_mixop)

let op_count statements name =
  statements
  |> List.fold_left (fun count statement ->
    match statement.node with
    | OpDecl declaration when declaration.name = name -> count + 1
    | _ -> count) 0

let constructor_typecheck_count statements constructor =
  statements
  |> List.fold_left (fun count statement ->
    match statement.node with
    | Eq (App ("typecheck", [ App (name, []); _ ]), Const "true", _)
    | Ceq (App ("typecheck", [ App (name, []); _ ]), Const "true", _, _)
      when name = constructor -> count + 1
    | _ -> count) 0

let require_unique_op_declarations statements =
  ignore
    (List.fold_left
       (fun seen statement ->
         match statement.node with
         | OpDecl declaration ->
           if List.exists (( = ) declaration) seen then
             failwith ("duplicate exact operator declaration: " ^ declaration.name);
           declaration :: seen
         | _ -> seen)
       [] statements)

let symbol = function
  | Const name | App (name, []) -> Some name
  | Var _ | Qid _ | App _ -> None

let is_typecheck witness constructor = function
  | Eq (App ("typecheck", [ App (op, _); typ ]), Const "true", _)
  | Ceq (App ("typecheck", [ App (op, _); typ ]), Const "true", _, _)
    when op = constructor && symbol typ = Some witness -> true
  | _ -> false

let has_typecheck statements category constructor =
  let witness = Naming.category_witness (id category) in
  List.exists
    (fun statement -> is_typecheck witness constructor statement.node)
    statements

let guard_witnesses guards =
  guards
  |> List.filter_map (function
    | BoolCond (App ("typecheck", [ _; witness ])) -> symbol witness
    | EqCond _ | MatchCond _ | MembershipCond _ | BoolCond _ -> None)

let identity_script order =
  let common = mixop "FLOWER" in
  let extra = mixop "THORN" in
  let source = "asteroid" in
  let middle = "brooklet" in
  let target = "cascade" in
  let definitions =
    [ source, variant source [ typcase nat_typ common ]
    ; middle, variant middle [ typcase nat_typ common ]
    ; target, variant target [ typcase nat_typ common; typcase nat_typ extra ]
    ]
  in
  let source_typ = category_typ source in
  let middle_typ = category_typ middle in
  let target_typ = category_typ target in
  common, extra, source, middle, target,
  List.map (fun name -> List.assoc name definitions) order
  @ [ coercion "retag_first" source_typ middle_typ (sube source_typ middle_typ)
    ; coercion "retag_second" middle_typ target_typ (sube middle_typ target_typ)
    ]

let test_transitive_identity_sharing_and_membership () =
  let common, extra, source, middle, target, script =
    identity_script [ "asteroid"; "brooklet"; "cascade" ]
  in
  let _, ctx, output = translate script in
  let shared = entry ctx source common in
  let middle_case = entry ctx middle common in
  let target_case = entry ctx target common in
  let shared_name = Naming.constructor_op common in
  if shared.constructor_op <> middle_case.constructor_op
     || shared.constructor_op <> target_case.constructor_op
  then failwith "transitive certified class did not share one representation";
  if shared.constructor_op <> shared_name then
    failwith "certified class did not use its unqualified mixop surface";
  if shared.projection_ops <> [ Naming.projection_op shared_name 0 ] then
    failwith "shared projection was not derived from the common surface";
  if op_count output.statements shared.constructor_op <> 1 then
    failwith "certified class did not emit exactly one constructor operator";
  require_unique_op_declarations output.statements;
  List.iter
    (fun category ->
      if not (has_typecheck output.statements category shared.constructor_op) then
        failwith ("shared constructor lost typecheck for " ^ category))
    [ source; middle; target ];
  let target_only = entry ctx target extra in
  if has_typecheck output.statements source target_only.constructor_op then
    failwith "target-only constructor acquired source membership";
  if not (has_typecheck output.statements target target_only.constructor_op) then
    failwith "target-only constructor lost target membership";
  if Helper.subtype_injections (Context.helpers ctx) <> [] then
    failwith "certified identity materialized a subtype helper";
  let source_typ = category_typ source in
  let target_typ = category_typ target in
  let pattern = sube source_typ target_typ in
  let lowered, _ =
    Expr_translate.lower_pattern_with_bindings_named
      Local_name.empty ctx Expr_env.empty
      (Origin.synthetic ~ast_constructor:"SubE" "shared-pattern") pattern
  in
  let witnesses = guard_witnesses lowered.pattern_guards in
  let source_witness = Naming.category_witness (id source) in
  let target_witness = Naming.category_witness (id target) in
  if not (List.mem source_witness witnesses) then
    failwith ("identity pattern lost guard " ^ source_witness);
  if List.mem target_witness witnesses then
    failwith ("identity pattern retained implied guard " ^ target_witness);
  if
    not
      (List.exists
         (fun binding -> binding.Expr_env.id = "seed")
         lowered.introduced_bindings)
  then failwith "identity pattern lost its source binding"

let test_canonical_choice_is_declaration_order_independent () =
  let common, _, source, _, target, script =
    identity_script [ "cascade"; "asteroid"; "brooklet" ]
  in
  let _, ctx, output = translate script in
  let canonical = (entry ctx source common).constructor_op in
  let expected = Naming.constructor_op common in
  if canonical <> expected then
    failwith "directed subtype chain did not choose its common mixop surface";
  let owner =
    Constructor_registry.canonical_owner
      (Context.constructors ctx) (entry ctx source common)
    |> Option.get
  in
  if owner.source_category <> target then
    failwith "synthetic surface replaced canonical source ownership";
  if op_count output.statements canonical <> 1 then
    failwith "declaration order changed canonical representation emission";
  let _, original_ctx, _ =
    identity_script [ "asteroid"; "brooklet"; "cascade" ] |> fun (_, _, _, _, _, script) ->
    translate script
  in
  if (entry original_ctx source common).constructor_op <> canonical then
    failwith "declaration order changed the canonical constructor name"

let graph_script mixop order edges =
  let definitions =
    order |> List.map (fun category -> variant category [ typcase nat_typ mixop ])
  in
  definitions
  @ List.mapi
      (fun index (source, target) ->
        let source_typ = category_typ source in
        let target_typ = category_typ target in
        coercion
          (Printf.sprintf "graph_retag_%d" index)
          source_typ target_typ (sube source_typ target_typ))
      edges

let representation_for mixop category order edges =
  let _, ctx, output = translate (graph_script mixop order edges) in
  require_unique_op_declarations output.statements;
  let selected = entry ctx category mixop in
  let owner =
    Constructor_registry.canonical_owner
      (Context.constructors ctx) selected
    |> Option.get
  in
  selected.constructor_op, owner.source_category

let test_diamond_sink_choice_is_deterministic () =
  let common = mixop "DIAMOND" in
  let edges = [ "river", "zinc"; "river", "amber" ] in
  let expected = Naming.constructor_op common, "amber" in
  List.iter
    (fun order ->
      if representation_for common "river" order edges <> expected then
        failwith "multi-sink subtype diamond changed its surface or least owner")
    [ [ "river"; "zinc"; "amber" ]; [ "amber"; "river"; "zinc" ] ]

let test_cycle_choice_is_deterministic () =
  let common = mixop "CYCLE" in
  let edges = [ "cedar", "birch"; "birch", "cedar" ] in
  let expected = Naming.constructor_op common, "birch" in
  List.iter
    (fun order ->
      if representation_for common "cedar" order edges <> expected then
        failwith "cyclic subtype class changed its surface or total least owner")
    [ [ "cedar"; "birch" ]; [ "birch"; "cedar" ] ]

let test_same_spelling_without_sube_stays_distinct () =
  let shared_spelling = mixop "SAME-SPELLING" in
  let _, ctx, output =
    translate
      [ variant "cairn" [ typcase nat_typ shared_spelling ]
      ; variant "delta" [ typcase nat_typ shared_spelling ]
      ]
  in
  let cairn = entry ctx "cairn" shared_spelling in
  let delta = entry ctx "delta" shared_spelling in
  if cairn.constructor_op = delta.constructor_op then
    failwith "unrelated same-spelled constructors were shared";
  if cairn.constructor_op
       <> Naming.constructor_op_in_category "cairn" shared_spelling
     || delta.constructor_op
        <> Naming.constructor_op_in_category "delta" shared_spelling
  then failwith "unrelated constructors lost their category-qualified surfaces";
  if op_count output.statements cairn.constructor_op <> 1
     || op_count output.statements delta.constructor_op <> 1
  then failwith "unrelated constructors did not emit independently"

let test_grammar_attribute_sube_certifies_sharing () =
  let shared = mixop "GRAMMAR-ATTRIBUTE" in
  let source = "grammar_source" in
  let target = "grammar_target" in
  let source_typ = category_typ source in
  let target_typ = category_typ target in
  let symbol =
    AttrG (sube source_typ target_typ, EpsG $ region) $ region
  in
  let production = ProdD ([], symbol, nat 0, []) $ region in
  let grammar = GramD (id "attribute_subtype", [], nat_typ, [ production ]) $ region in
  let _, ctx, _ =
    translate ~allow_fatal:true
      [ variant source [ typcase nat_typ shared ]
      ; variant target [ typcase nat_typ shared ]
      ; grammar
      ]
  in
  if (entry ctx source shared).constructor_op
     <> (entry ctx target shared).constructor_op
  then failwith "AttrG-only SubE was not collected from its GramD production symbol"

let test_inherited_open_variant_path_is_closed () =
  let child_region = region_of_file "synthetic-child.spectec" in
  let parent_region = region_of_file "synthetic-parent.spectec" in
  let atom_at region name =
    Xl.Atom.Atom name $$ region % Xl.Atom.info "representation-sharing"
  in
  let mixop_at region name =
    Xl.Mixop.Seq [ Xl.Mixop.Atom (atom_at region name); Xl.Mixop.Arg () ]
  in
  let inherited = typcase nat_typ (mixop_at child_region "INHERITED") in
  let native = typcase nat_typ (mixop_at parent_region "NATIVE") in
  let variant_at region name cases =
    TypD
      ( id name, []
      , [ InstD ([], [], VariantT cases $ region) $ region ] )
    $ region
  in
  let child = "lagoon" in
  let parent = "meadow" in
  let child_typ = category_typ child in
  let parent_typ = category_typ parent in
  let _, ctx, output =
    translate
      [ variant_at child_region child [ inherited ]
      ; variant_at parent_region parent [ inherited; native ]
      ; coercion "open_retag" child_typ parent_typ (sube child_typ parent_typ)
      ]
  in
  let inherited_mixop, _, _ = inherited in
  let native_mixop, _, _ = native in
  let child_case = entry ctx child inherited_mixop in
  if op_count output.statements child_case.constructor_op <> 1 then
    failwith "closed inherited path duplicated its child representation";
  if Helper.subtype_injections (Context.helpers ctx) <> [] then
    failwith "closed inherited identity path materialized a subtype helper";
  if not (has_typecheck output.statements parent child_case.constructor_op) then
    failwith "inherited representation lost parent membership";
  let parent_only = entry ctx parent native_mixop in
  if has_typecheck output.statements child parent_only.constructor_op then
    failwith "open parent-only constructor leaked into child membership"

let test_guard_mismatch_keeps_nonidentity_helper () =
  let guarded = mixop "GUARDED-FLOWER" in
  let false_prem = IfPr (BoolE false $$ region % bool_typ) $ region in
  let source = "ember" in
  let target = "fjord" in
  let source_typ = category_typ source in
  let target_typ = category_typ target in
  let _, ctx, output =
    translate
      [ variant source [ typcase ~prems:[ false_prem ] nat_typ guarded ]
      ; variant target [ typcase nat_typ guarded ]
      ; coercion "guarded_retag" source_typ target_typ (sube source_typ target_typ)
      ]
  in
  let source_case = entry ctx source guarded in
  let target_case = entry ctx target guarded in
  if source_case.constructor_op = target_case.constructor_op then
    failwith "guard-mismatched cases were shared";
  if op_count output.statements source_case.constructor_op <> 1
     || op_count output.statements target_case.constructor_op <> 1
  then failwith "guard-mismatched cases did not emit independently";
  match Helper.subtype_injections (Context.helpers ctx) with
  | [ _ ] -> ()
  | [] -> failwith "genuine nonidentity SubE lost its helper"
  | _ -> failwith "genuine nonidentity SubE requested multiple helpers"

let test_bound_case_stays_distinct () =
  let bounded = mixop "BOUND-FLOWER" in
  let bind = ExpP (id "limit", nat_typ) $ region in
  let source = "larch" in
  let target = "maple" in
  let source_typ = category_typ source in
  let target_typ = category_typ target in
  let _, ctx, _ =
    translate ~allow_fatal:true
      [ variant source [ typcase ~binds:[ bind ] nat_typ bounded ]
      ; variant target [ typcase ~binds:[ bind ] nat_typ bounded ]
      ; coercion "bound_retag" source_typ target_typ (sube source_typ target_typ)
      ]
  in
  if (entry ctx source bounded).constructor_op = (entry ctx target bounded).constructor_op
  then failwith "bound constructor cases were shared without a closed-domain proof"

let test_payload_mismatch_stays_distinct () =
  let leaf = mixop "LEAF" in
  let extra = mixop "EXTRA" in
  let wrapped = mixop "WRAPPED" in
  let small = category_typ "grain" in
  let large = category_typ "grove" in
  let source = category_typ "harbor" in
  let target = category_typ "island" in
  let _, ctx, output =
    translate ~allow_fatal:true
      [ variant "grain" [ typcase nat_typ leaf ]
      ; variant "grove" [ typcase nat_typ leaf; typcase nat_typ extra ]
      ; variant "harbor" [ typcase small wrapped ]
      ; variant "island" [ typcase large wrapped ]
      ; coercion "payload_retag" source target (sube source target)
      ]
  in
  let source_case = entry ctx "harbor" wrapped in
  let target_case = entry ctx "island" wrapped in
  if source_case.constructor_op = target_case.constructor_op then
    failwith "payload-mismatched cases were shared";
  if op_count output.statements source_case.constructor_op <> 1
     || op_count output.statements target_case.constructor_op <> 1
  then failwith "payload-mismatched cases did not emit independently"

let test_static_specialization_stays_distinct () =
  let specialized = mixop "SPECIAL" in
  let argument = ExpA (nat 1) $ region in
  let source = VarT (id "jetty", [ argument ]) $ region in
  let target = VarT (id "knoll", [ argument ]) $ region in
  let _, ctx, output =
    translate ~allow_fatal:true
      [ parameterized_variant "jetty" specialized
      ; parameterized_variant "knoll" specialized
      ; coercion "static_retag" source target (sube source target)
      ]
  in
  let source_case = entry ctx "jetty" specialized in
  let target_case = entry ctx "knoll" specialized in
  if source_case.constructor_op = target_case.constructor_op then
    failwith "static constructor cases were shared without an exact certificate";
  if op_count output.statements source_case.constructor_op <> 1
     || op_count output.statements target_case.constructor_op <> 1
  then failwith "static constructor cases did not emit independently"

let test_construction_domain_equality () =
  let guarded reason = Constructor_registry.Guarded_constructor reason in
  if
    not
      (Constructor_registry.same_construction_domain
         (guarded "closed source guard") (guarded "closed source guard"))
  then failwith "guarded construction-domain equality is not reflexive";
  if
    Constructor_registry.same_construction_domain
      (guarded "first guard") (guarded "second guard")
  then failwith "different guarded construction domains compared equal";
  let source_case domain =
    Constructor_registry.case_schema
      ~payload_typ:nat_typ ~case_binds:[] ~case_prems:[]
      ~instance_binds:[] ~instance_args:[] ~static_args_key:None
      ~construction_domain:domain
      ~origin:(Origin.synthetic ~ast_constructor:"VariantT" "guard-domain")
  in
  let guarded_case = source_case (guarded "same guard") in
  if not (Constructor_registry.same_case_schema guarded_case guarded_case) then
    failwith "guarded source-case equality is not reflexive"

let test_preload_schema_drift_is_rejected () =
  let case_mixop = mixop "SCHEMA-DRIFT" in
  let _, ctx, _ = translate [ variant "schema_owner" [ typcase nat_typ case_mixop ] ] in
  let preloaded = entry ctx "schema_owner" case_mixop in
  let drifted =
    { preloaded with
      projection_ops = []
    ; payload_sorts = [ sort "Int" ]
    ; payload_witnesses = [ Const "syn.changed" ]
    ; status = Constructor_registry.Unsupported
    ; construction_domain =
        Constructor_registry.Guarded_constructor "synthetic emission drift"
    }
  in
  match
    Constructor_registry.register_checked (Context.constructors ctx) drifted
  with
  | Constructor_registry.Schema_mismatch (expected, fields) ->
    if expected.origin <> preloaded.origin then
      failwith "schema drift diagnostic lost the preloaded source origin";
    List.iter
      (fun field ->
        if not (List.exists (String.starts_with ~prefix:field) fields) then
          failwith ("schema drift did not report " ^ field))
      [ "projection count"; "payload witnesses"; "payload sorts"; "status"
      ; "construction domain"
      ]
  | Constructor_registry.Registered
  | Constructor_registry.Already_registered
  | Constructor_registry.Rejected_after_resolution ->
    failwith "actual lowering schema drift was accepted"

let test_unqualified_shared_target_collision_is_rejected () =
  let shared = mixop "TARGET-COLLISION" in
  let pair left right typ =
    let left_typ = category_typ left in
    let right_typ = category_typ right in
    [ variant left [ typcase typ shared ]
    ; variant right [ typcase typ shared ]
    ; coercion (left ^ "_to_" ^ right) left_typ right_typ
        (sube left_typ right_typ)
    ]
  in
  let exact =
    Driver.translate
      (pair "orbit" "pulse" nat_typ @ pair "quartz" "ridge" nat_typ)
  in
  let incompatible =
    Driver.translate
      (pair "spruce" "tundra" nat_typ @ pair "upland" "valley" int_typ)
  in
  List.iter
    (fun (kind, result) ->
      if
        not
          (List.exists
             (fun diagnostic ->
               diagnostic.Diagnostics.constructor
               = "ConstructorRegistry/shared-surface-collision")
             result.Driver.diagnostics)
      then failwith (kind ^ " unqualified shared target collision was accepted");
      if not (Driver.has_fatal_diagnostics result) then
        failwith (kind ^ " unqualified shared target collision was not fatal"))
    [ "exact-signature" , exact; "incompatible-signature", incompatible ]

let test_final_module_shared_surface_collisions_are_rejected () =
  let shared = mixop "FINAL-SURFACE" in
  let source = "final_surface_left" in
  let target = "final_surface_right" in
  let source_typ = category_typ source in
  let target_typ = category_typ target in
  let _, ctx, output =
    translate
      [ variant source [ typcase nat_typ shared ]
      ; variant target [ typcase nat_typ shared ]
      ; coercion "final_surface_retag" source_typ target_typ
          (sube source_typ target_typ)
      ]
  in
  let registry = Context.constructors ctx in
  let owner = entry ctx source shared |> Constructor_registry.canonical_owner registry
    |> Option.get
  in
  let unrelated =
    Origin.synthetic ~ast_constructor:"OpDecl" "unrelated final operator"
  in
  let inject (declaration : Maude_ir.op_decl) =
    generated ~origin:unrelated
      (op ~kind:declaration.kind ~attrs:declaration.attrs
         declaration.name declaration.args declaration.result)
  in
  let assert_collision kind declaration =
    let diagnostics =
      Constructor_registry.module_surface_diagnostics
        ~profile:"constructor-equivalence-regression" registry
        (inject declaration :: output.statements)
    in
    if
      not
        (List.exists
           (fun diagnostic ->
             diagnostic.Diagnostics.constructor
             = "ConstructorRegistry/module-shared-target-collision")
           diagnostics)
    then failwith (kind ^ " exact final-module collision was accepted")
  in
  assert_collision "constructor" (Constructor_registry.constructor_declaration owner);
  assert_collision "projection"
    (Constructor_registry.projection_declarations owner |> List.hd);
  let owned_declaration = Constructor_registry.constructor_declaration owner in
  let duplicate_owned =
    generated ~origin:owner.origin
      (op ~kind:owned_declaration.kind ~attrs:owned_declaration.attrs
         owned_declaration.name owned_declaration.args owned_declaration.result)
  in
  if
    not
      (Constructor_registry.module_surface_diagnostics
         ~profile:"constructor-equivalence-regression" registry
         (duplicate_owned :: output.statements)
       |> List.exists (fun diagnostic ->
         diagnostic.Diagnostics.constructor
         = "ConstructorRegistry/module-shared-target-collision"))
  then failwith "same-origin duplicate owned declaration was consumed more than once";
  let prelude = mixop "len" in
  let left_typ = category_typ "prelude_left" in
  let right_typ = category_typ "prelude_right" in
  let prelude_result =
    Driver.translate
      [ variant "prelude_left" [ typcase nat_typ prelude ]
      ; variant "prelude_right" [ typcase nat_typ prelude ]
      ; coercion "prelude_retag" left_typ right_typ (sube left_typ right_typ)
      ]
  in
  if
    not
      (List.exists
         (fun diagnostic ->
           diagnostic.Diagnostics.constructor
             = "ConstructorRegistry/module-shared-target-collision")
         prelude_result.diagnostics)
  then failwith "shared target collision with a prelude overload was accepted";
  let keyword = mixop "op" in
  let keyword_left = category_typ "keyword_left" in
  let keyword_right = category_typ "keyword_right" in
  let keyword_result =
    Driver.translate
      [ variant "keyword_left" [ typcase nat_typ keyword ]
      ; variant "keyword_right" [ typcase nat_typ keyword ]
      ; coercion "keyword_retag" keyword_left keyword_right
          (sube keyword_left keyword_right)
      ]
  in
  if
    not
      (List.exists
         (fun diagnostic ->
           diagnostic.Diagnostics.constructor
             = "ConstructorRegistry/reserved-shared-surface")
         keyword_result.diagnostics)
  then failwith "shared target collision with a Maude keyword was accepted"

let test_numeric_wrapper_schema_mismatch_suppresses_emission () =
  let payload_id = id "payload" in
  let payload_typ = TupT [ payload_id, nat_typ ] $ region in
  let payload = typed_var nat_typ payload_id.it in
  let predicate =
    CmpE (`EqOp, `NatT, payload, nat 0) $$ region % bool_typ
  in
  let bind = ExpP (payload_id, nat_typ) $ region in
  let wrapper_mixop = Xl.Mixop.Seq [ Xl.Mixop.Arg () ] in
  let body =
    VariantT
      [ typcase ~binds:[ bind ] ~prems:[ IfPr predicate $ region ]
          payload_typ wrapper_mixop
      ]
    $ region
  in
  let source_category = "numeric_wrapper_owner" in
  let category_id = id source_category in
  let insts = [ InstD ([], [], body) $ region ] in
  let definition = TypD (category_id, [], insts) $ region in
  let script = [ definition ] in
  let source_index = Analysis.Source_index.of_script script in
  let origin =
    Origin.synthetic ~ast_constructor:"TypD" "numeric-wrapper-schema-drift"
  in
  let context () =
    Context.create source_index (Builtin_registry.of_source_index source_index)
    |> fun ctx -> Context.with_def ctx source_category
  in
  let preloaded_ctx = context () in
  Type_translate.preload_typd_registry
    preloaded_ctx origin category_id [] insts;
  let preloaded =
    match Constructor_registry.entries (Context.constructors preloaded_ctx) with
    | [ entry ] -> entry
    | entries ->
      failwith
        (Printf.sprintf
           "numeric wrapper preload produced %d entries" (List.length entries))
  in
  let ctx = context () in
  let registry = Context.constructors ctx in
  let registration =
    Constructor_registry.register_checked registry
      { preloaded with payload_sorts = [ sort "Int" ] }
  in
  (match registration with
  | Constructor_registry.Registered -> ()
  | Constructor_registry.Already_registered
  | Constructor_registry.Schema_mismatch _
  | Constructor_registry.Rejected_after_resolution ->
    failwith "synthetic numeric wrapper preload did not register exactly once");
  Constructor_registry.resolve
    ~il_env:(Context.il_env ctx) ~source_index registry script;
  let lowered =
    Type_translate.translate_typd ctx origin category_id [] insts
  in
  let wrapper = Naming.wrapper_constructor_in_category source_category in
  if
    List.exists
      (fun statement ->
        match statement.node with
        | OpDecl declaration -> declaration.name = wrapper
        | Mb (App (name, _), _)
        | Cmb (App (name, _), _, _) -> name = wrapper
        | Eq (App ("typecheck", [ App (name, _); _ ]), _, _)
        | Ceq (App ("typecheck", [ App (name, _); _ ]), _, _, _) ->
          name = wrapper
        | SortDecl _ | SubsortDecl _ | VarDecl _ | Mb _ | Cmb _
        | Eq _ | Ceq _ | Rl _ | Crl _ -> false)
      lowered.statements
  then failwith "numeric wrapper schema mismatch emitted wrapper statements";
  match lowered.diagnostics with
  | diagnostics
    when List.exists
           (fun diagnostic ->
             diagnostic.Diagnostics.constructor
             = "VariantT/numeric-wrapper/resolved-registry"
             && diagnostic.origin = preloaded.origin)
           diagnostics -> ()
  | diagnostics ->
    failwith
      ("numeric wrapper schema mismatch lost its source-origin Unsupported: "
       ^ Diagnostics.render_all diagnostics)

let test_parameterized_nullary_declaration_has_one_owner () =
  let parameter = ExpP (id "limit", nat_typ) $ region in
  let nullary = Xl.Mixop.Atom (atom "PARAMETERIZED-NULLARY") in
  let payload = TupT [] $ region in
  let body = VariantT [ typcase payload nullary ] $ region in
  let inst value =
    InstD ([], [ ExpA (nat value) $ region ], body) $ region
  in
  let category = "parameterized_nullary_owner" in
  let definition =
    TypD (id category, [ parameter ], [ inst 1; inst 2 ]) $ region
  in
  let result = Driver.translate [ definition ] in
  if Driver.has_fatal_diagnostics result then
    failwith (Diagnostics.render_all result.diagnostics);
  let constructor = Naming.constructor_op_in_category category nullary in
  if op_count result.module_.statements constructor <> 1 then
    failwith "parameterized nullary constructor did not select one OpDecl owner";
  if constructor_typecheck_count result.module_.statements constructor <> 2 then
    failwith "parameterized nullary constructor lost an instance typecheck equation";
  require_unique_op_declarations result.module_.statements

let test_resolved_registry_rejects_late_source_facts () =
  let registry = Constructor_registry.create () in
  let covered = Origin.synthetic ~ast_constructor:"VariantT" "covered case" in
  let original = Origin.synthetic ~ast_constructor:"TypD" "original inclusion" in
  let inclusion =
    { Constructor_registry.parent_category = "resolved_parent"
    ; parent_static_args_key = None
    ; child_category = "resolved_child"
    ; child_static_args_key = None
    ; origin = original
    ; covered_origins = [ covered ]
    ; reason = "resolved lifecycle regression"
    }
  in
  Constructor_registry.note_source_case registry
    ~source_category:"resolved_parent" ~static_args_key:None covered;
  Constructor_registry.register_inclusion registry inclusion;
  Constructor_registry.resolve
    ~il_env:Il.Env.empty
    ~source_index:(Analysis.Source_index.of_script [])
    registry [];
  Constructor_registry.note_source_case registry
    ~source_category:"resolved_parent" ~static_args_key:None covered;
  Constructor_registry.register_inclusion registry inclusion;
  let late_case =
    Origin.synthetic
      ~source_echo:"late source case"
      ~path:[ "late-parent"; "VariantT[1]" ]
      ~ast_constructor:"VariantT" "late case"
  in
  let late_inclusion_origin =
    Origin.synthetic
      ~source_echo:"late category inclusion"
      ~path:[ "late-parent"; "category-union" ]
      ~ast_constructor:"TypD" "late inclusion"
  in
  let late_inclusion =
    { inclusion with origin = late_inclusion_origin }
  in
  Constructor_registry.note_source_case registry
    ~source_category:"late_parent" ~static_args_key:None late_case;
  Constructor_registry.register_inclusion registry late_inclusion;
  if Constructor_registry.inclusions registry <> [ inclusion ] then
    failwith "resolved registry accepted a late inclusion mutation";
  (match
     Constructor_registry.family_coverage registry
       ~source_category:"late_parent" ~static_args_key:None
   with
  | Constructor_registry.Open blockers
    when List.exists
           (String.starts_with ~prefix:"no recorded source VariantT cases")
           blockers -> ()
  | Constructor_registry.Open _ ->
    failwith "late source case changed resolved family coverage"
  | Constructor_registry.Closed _ ->
    failwith "late source case closed a resolved constructor family");
  let diagnostics =
    Constructor_registry.diagnostics
      ~profile:"constructor-equivalence-regression" registry
  in
  List.iter
    (fun (constructor, origin) ->
      match
        List.find_opt
          (fun diagnostic ->
            diagnostic.Diagnostics.constructor = constructor
            && diagnostic.category = Diagnostics.Unsupported)
          diagnostics
      with
      | Some diagnostic
        when diagnostic.enclosing = origin.Origin.path
             && diagnostic.source_echo = origin.source_echo -> ()
      | Some _ -> failwith (constructor ^ " lost its source provenance")
      | None -> failwith (constructor ^ " lacked an explicit late-fact Unsupported"))
    [ "ConstructorRegistry/late-inclusion", late_inclusion_origin
    ; "ConstructorRegistry/late-source-case", late_case
    ]

let test_inadmissible_category_union_is_not_registered () =
  let child = "inadmissible_child" in
  let child_definition =
    TypD
      (id child, [],
       [ InstD ([], [], AliasT (TupT [] $ region) $ region) $ region ])
    $ region
  in
  let parent_definition =
    variant "inadmissible_parent"
      [ typcase (category_typ child) (Xl.Mixop.Seq [ Xl.Mixop.Arg () ]) ]
  in
  let result = Driver.translate [ child_definition; parent_definition ] in
  if not (Driver.has_fatal_diagnostics result) then
    failwith "inadmissible category union did not retain its carrier diagnostic";
  if
    result.diagnostics
    |> List.exists (fun diagnostic ->
      diagnostic.Diagnostics.constructor = "ConstructorRegistry/late-inclusion")
  then failwith "inadmissible category union attempted late inclusion registration"

let test_multi_origin_inclusion_closes_covered_cases () =
  let registry = Constructor_registry.create () in
  let parent = "covered_parent" in
  let child = "covered_child" in
  let left = Origin.synthetic ~ast_constructor:"VariantT" "covered left" in
  let right = Origin.synthetic ~ast_constructor:"VariantT" "covered right" in
  let child_origin = Origin.synthetic ~ast_constructor:"VariantT" "covered child" in
  Constructor_registry.note_source_case registry
    ~source_category:parent ~static_args_key:None left;
  Constructor_registry.note_source_case registry
    ~source_category:parent ~static_args_key:None right;
  Constructor_registry.note_source_case registry
    ~source_category:child ~static_args_key:None child_origin;
  Constructor_registry.register registry
    { Constructor_registry.source_category = child
    ; declaring_category = child
    ; static_args_key = None
    ; mixop = Xl.Mixop.Atom (atom "COVERED-CHILD")
    ; arity = 0
    ; constructor_op = "covered.child"
    ; projection_ops = []
    ; payload_labels = []
    ; payload_typs = []
    ; payload_witnesses = []
    ; payload_sorts = []
    ; source_case = None
    ; origin = child_origin
    ; enclosing = []
    ; status = Constructor_registry.Emitted
    ; construction_domain = Constructor_registry.Total_constructor
    };
  Constructor_registry.register_inclusion registry
    { parent_category = parent
    ; parent_static_args_key = None
    ; child_category = child
    ; child_static_args_key = None
    ; origin = Origin.synthetic ~ast_constructor:"TypD" "covered inclusion"
    ; covered_origins = [ left; right ]
    ; reason = "multi-origin coverage regression"
    };
  match
    Constructor_registry.family_coverage registry
      ~source_category:parent ~static_args_key:None
  with
  | Constructor_registry.Closed [ _ ] -> ()
  | Constructor_registry.Closed _ ->
    failwith "multi-origin inclusion changed the inherited constructor count"
  | Constructor_registry.Open blockers ->
    failwith
      ("covered source cases left their constructor family open: "
       ^ String.concat "; " blockers)

let test_incompatible_declaration_surface_is_rejected () =
  let registry = Constructor_registry.create () in
  let projection = "proj.shared-surface.0" in
  let shared_origin =
    Origin.synthetic ~ast_constructor:"VariantT" "shared declaration origin"
  in
  let make category constructor payload_sort =
    { Constructor_registry.source_category = category
    ; declaring_category = category
    ; static_args_key = None
    ; mixop = mixop "DECLARATION-SURFACE"
    ; arity = 1
    ; constructor_op = constructor
    ; projection_ops = [ projection ]
    ; payload_labels = [ Constructor_registry.Structural_payload ]
    ; payload_typs = [ nat_typ ]
    ; payload_witnesses = [ Const "syn.payload" ]
    ; payload_sorts = [ payload_sort ]
    ; source_case = None
    ; origin = shared_origin
    ; enclosing = []
    ; status = Constructor_registry.Emitted
    ; construction_domain = Constructor_registry.Total_constructor
    }
  in
  Constructor_registry.register registry
    (make "left_surface" "left.surface" (sort "Nat"));
  Constructor_registry.register registry
    (make "right_surface" "right.surface" (sort "Int"));
  if
    not
      (Constructor_registry.diagnostics ~profile:"constructor-equivalence-regression" registry
       |> List.exists (fun diagnostic ->
         diagnostic.Diagnostics.constructor
         = "ConstructorRegistry/op-declaration-collision"))
  then failwith "incompatible typed declarations on one surface were accepted"

let () =
  test_transitive_identity_sharing_and_membership ();
  test_canonical_choice_is_declaration_order_independent ();
  test_diamond_sink_choice_is_deterministic ();
  test_cycle_choice_is_deterministic ();
  test_same_spelling_without_sube_stays_distinct ();
  test_grammar_attribute_sube_certifies_sharing ();
  test_inherited_open_variant_path_is_closed ();
  test_guard_mismatch_keeps_nonidentity_helper ();
  test_bound_case_stays_distinct ();
  test_payload_mismatch_stays_distinct ();
  test_static_specialization_stays_distinct ();
  test_construction_domain_equality ();
  test_preload_schema_drift_is_rejected ();
  test_unqualified_shared_target_collision_is_rejected ();
  test_final_module_shared_surface_collisions_are_rejected ();
  test_numeric_wrapper_schema_mismatch_suppresses_emission ();
  test_parameterized_nullary_declaration_has_one_owner ();
  test_resolved_registry_rejects_late_source_facts ();
  test_inadmissible_category_union_is_not_registered ();
  test_multi_origin_inclusion_closes_covered_cases ();
  test_incompatible_declaration_surface_is_rejected ()
