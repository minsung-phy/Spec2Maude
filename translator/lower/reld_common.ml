open Il.Ast
open Maude_ir
open Util.Source

type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let empty = { statements = []; diagnostics = [] }

let append left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let source_echo origin =
  origin.Origin.source_echo

let diagnostic ?suggestion ?source_echo ~category ~ctx ~origin ~constructor ~reason () =
  Diagnostics.make
    ?suggestion
    ?source_echo
    ~category
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let unsupported ?suggestion ?source_echo:diagnostic_source_echo ~ctx ~origin ~constructor ~reason () =
  let source_echo =
    match diagnostic_source_echo with
    | Some source_echo -> Some source_echo
    | None -> source_echo origin
  in
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Unsupported
    ~ctx
    ~origin
    ~constructor
    ~reason
    ()

let skipped ?suggestion ?source_echo:diagnostic_source_echo ~ctx ~origin ~constructor ~reason () =
  let source_echo =
    match diagnostic_source_echo with
    | Some source_echo -> Some source_echo
    | None -> source_echo origin
  in
  diagnostic
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Skipped
    ~ctx
    ~origin
    ~constructor
    ~reason
    ()

let one_diagnostic diagnostic =
  { empty with diagnostics = [ diagnostic ] }

let has_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let gen origin node =
  Maude_ir.generated ~origin node

let app name args =
  App (name, args)

let dedup_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let dedup_rule_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let dedup_generated statements =
  let rec loop seen = function
    | [] -> List.rev seen
    | statement :: rest ->
      if List.exists (fun old -> old.Maude_ir.node = statement.Maude_ir.node) seen then
        loop seen rest
      else
        loop (statement :: seen) rest
  in
  loop [] statements

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let rule_origin parent index rule =
  child_origin
    parent
    (Printf.sprintf "RuleD[%d]" index)
    "RuleD"
    rule.at
    (Some (Il.Print.string_of_rule rule))

let rule_label relation_id rule_id index =
  let material =
    if rule_id.it = "" || rule_id.it = "_" then
      relation_id.it ^ "-rule-" ^ string_of_int index
    else
      relation_id.it ^ "-" ^ rule_id.it
  in
  Maude_ir.sanitize_label material

let relation_marker_diagnostics
    ctx
    origin
    ~constructor
    ~source_echo
    ~expected
    ~actual
  =
  if expected = actual then
    []
  else
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo
        ~reason:
          (Printf.sprintf
             "source relation marker mismatch: enclosing/referenced relation is `%s`, but this local mixop is `%s`"
             (Analysis.Relation_graph.string_of_relation_kind expected)
             (Analysis.Relation_graph.string_of_relation_kind actual))
        ~suggestion:
          "Do not erase the local RuleD/RulePr mixop; either prove it matches the referenced relation structurally or keep this case Unsupported"
        ()
    ]

let relation_mixop_skeleton_diagnostics
    ctx
    origin
    ~constructor
    ~source_echo
    ~expected
    ~actual
  =
  if Analysis.Relation_graph.eq_mixop expected actual then
    []
  else
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo
        ~reason:
          (Printf.sprintf
             "source relation mixop skeleton mismatch: enclosing/referenced relation uses `%s`, but this local mixop is `%s`"
             (Analysis.Relation_graph.mixop_shape_text expected)
             (Analysis.Relation_graph.mixop_shape_text actual))
        ~suggestion:
          "Do not collapse distinct source relation skeletons just because their marker class or arity matches"
        ()
    ]

let validate_rule_marker ctx origin ~expected_kind ~expected_mixop rule =
  match rule.it with
  | RuleD (_, _, mixop, _, _) ->
    relation_marker_diagnostics
      ctx
      origin
      ~constructor:"RelD/RuleD/mixop"
      ~source_echo:(Il.Print.string_of_rule rule)
      ~expected:expected_kind
      ~actual:(Analysis.Relation_graph.classify_mixop mixop)
    @ relation_mixop_skeleton_diagnostics
        ctx
        origin
        ~constructor:"RelD/RuleD/mixop-skeleton"
        ~source_echo:(Il.Print.string_of_rule rule)
        ~expected:expected_mixop
        ~actual:mixop

let validate_rule_premise_marker ctx origin ~expected_kind ~expected_mixop prem mixop =
  relation_marker_diagnostics
    ctx
    origin
    ~constructor:"Premise/RulePr/mixop"
    ~source_echo:(Il.Print.string_of_prem prem)
    ~expected:expected_kind
    ~actual:(Analysis.Relation_graph.classify_mixop mixop)
  @ relation_mixop_skeleton_diagnostics
      ctx
      origin
      ~constructor:"Premise/RulePr/mixop-skeleton"
      ~source_echo:(Il.Print.string_of_prem prem)
      ~expected:expected_mixop
      ~actual:mixop

let maude_var_of_bind seed index id =
  if id.it = "_" then
    Naming.maude_var (seed ^ "-wild-" ^ string_of_int index)
  else
    Naming.maude_var (seed ^ "-" ^ string_of_int index ^ "-" ^ id.it)

let unsupported_type ctx origin constructor typ =
  unsupported
    ~ctx
    ~origin
    ~constructor
    ~reason:
      ("unsupported RelD carrier type `" ^ Il.Print.string_of_typ typ ^ "`")
    ~suggestion:
      "Add a source-preserving carrier/witness encoding for this relation component before lowering the RelD"
    ()

let component_sort ctx origin constructor typ =
  match Expr_translate.carrier_sort_of_typ typ with
  | Some sort -> Some sort, []
  | None -> None, [ unsupported_type ctx origin constructor typ ]

let component_sorts ctx origin constructor typs =
  let results = List.map (component_sort ctx origin constructor) typs in
  let sorts = List.filter_map fst results in
  let diagnostics = List.concat (List.map snd results) in
  if List.length sorts = List.length typs then
    Some sorts, diagnostics
  else
    None, diagnostics

let sequence_of_terms = function
  | [] -> Const "eps"
  | term :: terms ->
    List.fold_left (fun acc term -> app "_ _" [ acc; term ]) term terms

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let tuple_item sort term =
  if is_sequence_sort sort then app "seq" [ term ] else term

let tuple_carrier sorts terms =
  match sorts, terms with
  | [ _ ], [ term ] -> term
  | _ ->
    let items = List.map2 tuple_item sorts terms in
    app "tuple" [ sequence_of_terms items ]

let execution_output_sort = function
  | [ sort ] -> sort
  | _ -> sort "SpectecTerminal"

let relation_conf_sort id =
  let relation_slug = Naming.relation_op id in
  let suffix =
    relation_slug
    |> String.to_seq
    |> Seq.filter (function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
      | _ -> false)
    |> String.of_seq
    |> String.uppercase_ascii
  in
  sort ("RelConf" ^ if suffix = "" then "REL" else suffix)

let frozen_all count =
  let rec loop index acc =
    if index = 0 then acc else loop (index - 1) (index :: acc)
  in
  match loop count [] with
  | [] -> []
  | positions -> [ Frozen positions ]

let lower_exp_bind ctx origin seed index env bind =
  match bind.it with
  | ExpP (id, typ) ->
    if id.it = "_" then
      env,
      [],
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"RelD/RuleD/ExpP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "wildcard ExpP bind cannot be referenced safely in generated relation rule scope"
          ~suggestion:
            "Implement anonymous pattern bind handling before lowering this RuleD"
          ()
      ]
    else
      (match Expr_translate.carrier_sort_of_typ typ with
      | Some sort ->
        let name = maude_var_of_bind seed index id in
        let binding = { Expr_translate.term = Var name; sort; typ } in
        let env = Expr_translate.add_var env id.it binding in
        env, [ gen origin (var name (Expr_translate.type_ref_of_sort sort)) ], []
      | None ->
        env, [], [ unsupported_type ctx origin "RelD/RuleD/ExpP" typ ])
  | TypP id ->
    if Context.find_static_typ ctx id.it <> None then
      env,
      [],
      [ skipped
          ~ctx
          ~origin
          ~constructor:"RelD/RuleD/bind/TypP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time syntax binder is already fixed by the current specialization and has no runtime Maude variable"
          ~suggestion:
            "Keep the binder origin in diagnostics; do not emit it as a runtime argument"
          ()
      ]
    else
      env,
      [],
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"RelD/RuleD/bind/TypP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time syntax binder is not bound by the current specialization, so erasing it would collapse source structure"
          ~suggestion:
            "Extend finite monomorphization to introduce this local static binder before lowering the RuleD"
          ()
      ]
  | DefP _ | GramP _ ->
    env,
    [],
    [ unsupported
        ~ctx
        ~origin
        ~constructor:"RelD/RuleD/static-bind"
        ~source_echo:(Il.Print.string_of_quant bind)
        ~reason:
          "definition/grammar static RuleD binds require monomorphization and are outside this relation lowering slice"
        ~suggestion:
          "Specialize the enclosing relation rule before lowering this static binder"
        ()
    ]

let translate_rule_binds ctx origin seed binds =
  binds
  |> List.mapi (fun index bind -> index + 1, bind)
  |> List.fold_left
       (fun (env, statements, diagnostics) (index, bind) ->
         let env, new_statements, new_diagnostics =
           lower_exp_bind ctx origin seed index env bind
         in
         env, statements @ new_statements, diagnostics @ new_diagnostics)
       (Expr_translate.empty_env, [], [])

let add_introduced_bindings env bindings =
  bindings
  |> List.fold_left
       (fun env (id, binding) -> Expr_translate.add_var env id binding)
       env

let lhs_bound_vars terms guards =
  Condition_closure.conditions_bound_vars
    (terms
     |> List.map Condition_closure.term_vars
     |> List.concat
     |> List.sort_uniq String.compare)
    guards

let add_safe_introduced_bindings env terms guards bindings =
  let bound_vars = lhs_bound_vars terms guards in
  bindings
  |> List.fold_left
       (fun env (id, (binding : Expr_translate.binding)) ->
         if
           Expr_translate.find_var env id = None
           && Condition_closure.vars_subset
                (Condition_closure.term_vars binding.term)
                bound_vars
         then
           Expr_translate.add_var env id binding
         else
           env)
       env

let exp_components_match ctx origin constructor expected_typs exp =
  match Analysis.Relation_graph.exp_components_for_count (List.length expected_typs) exp with
  | Some components -> Some components, []
  | None ->
    None,
    [ unsupported
        ~ctx
        ~origin
        ~constructor
        ~source_echo:(Il.Print.string_of_exp exp)
        ~reason:
          (Printf.sprintf
             "relation rule body does not match the enclosing RelD signature with %d component(s) without flattening source tuple structure"
             (List.length expected_typs))
        ~suggestion:
          "Preserve the source RuleD tuple/mixop shape before lowering this relation rule"
        ()
    ]

let lower_pattern_components ctx env origin exps =
  let results =
    exps
    |> List.mapi (fun index exp ->
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "lhs[%d]" (index + 1))
          "RuleD/LhsExpr"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      Expr_translate.lower_pattern_with_bindings ctx env exp_origin exp)
  in
  let terms =
    List.filter_map
      (fun (result : Expr_translate.pattern_result) -> result.pattern_term)
      results
  in
  let guards =
    results
    |> List.map (fun (result : Expr_translate.pattern_result) -> result.pattern_guards)
    |> List.concat
  in
  let bindings =
    results
    |> List.map (fun (result : Expr_translate.pattern_result) -> result.introduced_bindings)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (result : Expr_translate.pattern_result) -> result.pattern_diagnostics)
    |> List.concat
  in
  if List.length terms = List.length exps then
    Some terms, guards, bindings, diagnostics
  else
    None, guards, bindings, diagnostics

let lower_value_components ctx env origin segment exps =
  let results =
    exps
    |> List.mapi (fun index exp ->
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "%s[%d]" segment (index + 1))
          "RuleD/Expr"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      Expr_translate.lower_value ctx env exp_origin exp)
  in
  let terms =
    List.filter_map
      (fun (result : Expr_translate.result) -> result.term)
      results
  in
  let guards =
    results
    |> List.map (fun (result : Expr_translate.result) -> result.guards)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (result : Expr_translate.result) -> result.diagnostics)
    |> List.concat
  in
  if List.length terms = List.length exps then
    Some terms, guards, diagnostics
  else
    None, guards, diagnostics

let relation_call op_name inputs =
  app op_name inputs

let generated_statement_diagnostics ctx statement =
  let _registry, violations = Maude_registry.build [ statement ] in
  Maude_registry.diagnostics
    ~profile:(Context.profile_name ctx)
    violations

let rule_hint_diagnostics ctx origin relation_id rule_id =
  match
    Analysis.Function_graph.rule_hints
      (Context.function_graph ctx)
      ~relation_id
      ~rule_id:rule_id.it
  with
  | None -> []
  | Some rule_hint ->
    rule_hint.hints
    |> List.map (fun hint ->
      let constructor = "RuleD/RuleH/hint(" ^ hint.hintid.it ^ ")" in
      let source_echo =
        Some
          ("RuleH "
           ^ relation_id
           ^ "/"
           ^ rule_id.it
           ^ " hint("
           ^ hint.hintid.it
           ^ ")")
      in
      match Analysis.Hint_policy.classify hint with
      | Analysis.Hint_policy.Presentation ->
        skipped
          ~ctx
          ~origin
          ~constructor
          ?source_echo
          ~reason:
            "rule-local presentation hint is preserved as metadata and does not affect Maude lowering"
          ~suggestion:
            "Keep the RuleH attached to the source rule; no Maude semantic fragment is required for presentation hints"
          ()
      | Analysis.Hint_policy.Semantic_obligation
      | Analysis.Hint_policy.Translator_annotation
      | Analysis.Hint_policy.Unknown ->
        unsupported
          ~ctx
          ~origin
          ~constructor
          ?source_echo
          ~reason:
            ("rule-local hint `"
             ^ hint.hintid.it
             ^ "` is not consumed by this RuleD lowering path")
          ~suggestion:
            "Add a source-shaped RuleH policy before emitting Maude for rules carrying semantic or unknown rule-local hints"
          ())
