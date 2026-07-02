open Il.Ast
open Maude_ir
open Util.Source

include Reld_common

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

let append_execution_premise_result left right =
  { Premise_translate.eq_conditions =
      []
  ; rule_conditions =
      left.Premise_translate.rule_conditions
      @ List.map
          (fun condition -> EqCondition condition)
          right.Premise_translate.eq_conditions
      @ right.Premise_translate.rule_conditions
  ; has_else = left.Premise_translate.has_else || right.Premise_translate.has_else
  ; let_bound_ids =
      left.Premise_translate.let_bound_ids @ right.Premise_translate.let_bound_ids
  ; env_after = right.Premise_translate.env_after
  ; bound_vars_after = right.Premise_translate.bound_vars_after
  ; blocked_witness_source_ids =
      List.sort_uniq
        String.compare
        (left.Premise_translate.blocked_witness_source_ids
         @ right.Premise_translate.blocked_witness_source_ids)
  ; runtime_search_requests =
      left.Premise_translate.runtime_search_requests
      @ right.Premise_translate.runtime_search_requests
  ; runtime_truth_search_requests =
      left.Premise_translate.runtime_truth_search_requests
      @ right.Premise_translate.runtime_truth_search_requests
  ; diagnostics = left.Premise_translate.diagnostics @ right.Premise_translate.diagnostics
  }

let unsupported_rule_prem ctx env ~bound_vars origin prem constructor reason =
  let result =
    Premise_translate.translate_premise ctx env ~bound_vars origin prem
  in
  { result with
    Premise_translate.diagnostics =
      result.Premise_translate.diagnostics
      @ [ unsupported
            ~ctx
            ~origin
            ~constructor
            ~source_echo:(Il.Print.string_of_prem prem)
            ~reason
            ~suggestion:
              "Keep this RulePr Unsupported until the enclosing relation lowering can preserve its source operational meaning"
            ()
        ]
  }

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

let lower_execution_rule_premise ctx env ~bound_vars origin prem rel_id exp =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
  | None ->
    unsupported_rule_prem
      ctx
      env
      ~bound_vars
      origin
      prem
      "Premise/RulePr/unresolved"
      ("relation premise references `" ^ rel_id.it ^ "`, but no matching RelD was found in the source index")
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    (match relation_shape.Relation_shape.decision with
    | Relation_shape.Execution { inputs; outputs; _ } ->
      let input_typs = Relation_shape.component_typs inputs in
      let output_typs = Relation_shape.component_typs outputs in
      (match exp_components_match ctx origin "Premise/RulePr/execution/arity" (input_typs @ output_typs) exp with
      | None, arity_diags ->
        { (Premise_translate.empty) with
          env_after = env
        ; bound_vars_after = bound_vars
        ; diagnostics = arity_diags
        }
      | Some components, arity_diags ->
        let input_count = List.length input_typs in
        let input_exps, output_exps =
          let rec split n left right =
            if n = 0 then List.rev left, right
            else
              match right with
              | [] -> List.rev left, []
              | item :: rest -> split (n - 1) (item :: left) rest
          in
          split input_count [] components
        in
        let input_terms_opt, input_guards, input_diags =
          lower_value_components ctx env origin "rewrite-input" input_exps
        in
        let output_sorts_opt, output_sort_diags =
          component_sorts
            ctx
            origin
            "Premise/RulePr/execution/output"
            output_typs
        in
        let output_pattern_opt, output_guards, introduced, output_diags =
          lower_pattern_components ctx env origin output_exps
        in
        (match input_terms_opt, output_pattern_opt, output_sorts_opt with
        | Some input_terms, Some output_patterns, Some output_sorts
          when List.length output_patterns = List.length output_sorts ->
          let output_pattern = tuple_carrier output_sorts output_patterns in
          let lhs = relation_call (Naming.relation_op rel_id) input_terms in
          let rewrite_condition = RewriteCond (lhs, output_pattern) in
          let rule_conditions =
            rewrite_condition
            :: List.map (fun condition -> EqCondition condition) output_guards
          in
          let env_after = add_introduced_bindings env introduced in
          let bound_vars_after =
            Condition_closure.conditions_bound_vars bound_vars input_guards
            |> fun bound ->
            Condition_closure.rule_conditions_bound_vars bound rule_conditions
            |> List.sort_uniq String.compare
          in
          { (Premise_translate.empty) with
            eq_conditions = input_guards
          ; rule_conditions
          ; env_after
          ; bound_vars_after
          ; diagnostics =
              arity_diags @ input_diags @ output_sort_diags @ output_diags
          }
        | _ ->
          { (Premise_translate.empty) with
            env_after = env
          ; bound_vars_after = bound_vars
          ; diagnostics =
              arity_diags @ input_diags @ output_sort_diags @ output_diags
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/RulePr/execution/output"
                    ~source_echo:(Il.Print.string_of_prem prem)
                    ~reason:
                      "execution RulePr lowering currently supports exactly one output component, so multi-output execution premises remain Unsupported"
                    ()
                ]
          }))
    | _ ->
      unsupported_rule_prem
        ctx
        env
        ~bound_vars
        origin
        prem
        "Premise/RulePr/execution"
        "relation premise is not structurally classified as an execution relation with a split input/output signature")

let prem_origin parent prem =
  Origin.with_child
    ~source_echo:(Il.Print.string_of_prem prem)
    parent
    "premise"
    ~ast_constructor:"Premise"
    prem.at

let translate_execution_premise
    ctx
    env
    ~bound_vars
    ~blocked_witness_source_ids
    ~future_prems
    ~escape_source_ids
    origin
  prem =
  let origin = prem_origin origin prem in
  match prem.it with
  | RulePr (rel_id, args, mixop, exp) ->
    if args <> [] then
      { Premise_translate.empty with
        env_after = env
      ; bound_vars_after = bound_vars
      ; diagnostics =
          [ unsupported
              ~ctx
              ~origin
              ~constructor:"RelD/RulePr/args"
              ~source_echo:(Il.Print.string_of_prem prem)
              ~reason:
                ("execution premise `"
                 ^ rel_id.it
                 ^ "` carries explicit RulePr arguments `"
                 ^ Il.Print.string_of_args args
                 ^ "`, but relation-argument instantiation is not lowered yet")
              ~suggestion:
                "Preserve the RulePr args in analysis and add source-shaped argument instantiation before emitting Maude for this execution premise"
              ()
          ]
      }
    else
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | Some relation ->
      let marker_diags =
        validate_rule_premise_marker
          ctx
          origin
          ~expected_kind:relation.Analysis.Function_graph.kind
          ~expected_mixop:relation.Analysis.Function_graph.mixop
          prem
          mixop
      in
      if has_fatal marker_diags then
        { Premise_translate.empty with
          env_after = env
        ; bound_vars_after = bound_vars
        ; diagnostics = marker_diags
        }
      else
      let relation_shape = Relation_shape.of_relation relation in
      (match relation_shape.Relation_shape.decision with
      | Relation_shape.Execution _ ->
        lower_execution_rule_premise ctx env ~bound_vars origin prem rel_id exp
      | Relation_shape.Deterministic_candidate _ ->
        Premise_translate.translate_premise
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem
      | Relation_shape.Static_validation _ ->
        Premise_translate.translate_premise
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem
      | Relation_shape.Runtime_predicate _ | Relation_shape.Unknown _ ->
        Premise_translate.translate_premise
          ~allow_runtime_search:true
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem)
    | None ->
      Premise_translate.translate_premise
        ~allow_runtime_search:true
        ~future_prems
        ~escape_source_ids
        ~blocked_witness_source_ids
        ctx
        env
        ~bound_vars
        origin
        prem)
  | IfPr _ | LetPr _ ->
    Premise_translate.translate_premise
      ~allow_runtime_search:true
      ~future_prems
      ~escape_source_ids
      ~blocked_witness_source_ids
      ctx
      env
      ~bound_vars
      origin
      prem
  | ElsePr ->
    let result =
      Premise_translate.translate_premise
        ~allow_runtime_search:true
        ~future_prems
        ~escape_source_ids
        ~blocked_witness_source_ids
        ctx
        env
        ~bound_vars
        origin
        prem
    in
    { result with
      diagnostics =
        result.diagnostics
        @ [ unsupported
              ~ctx
              ~origin
              ~constructor:"RelD/RuleD/ElsePr"
              ~source_echo:(Il.Print.string_of_prem prem)
              ~reason:
                "execution relation otherwise requires a source-derived enabledness complement helper; Maude rule [owise] is not legal here"
              ~suggestion:
                "Implement enabledness complement before lowering execution ElsePr"
              ()
          ]
    }
  | IterPr _ | NegPr _ ->
    Premise_translate.translate_premise
      ~allow_runtime_search:true
      ~future_prems
      ~escape_source_ids
      ~blocked_witness_source_ids
      ctx
      env
      ~bound_vars
      origin
      prem

let translate_execution_premises
    ctx env ?(bound_conditions = []) ?(escape_source_ids = []) ~bound_terms origin prems =
  let bound_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> List.sort_uniq String.compare
    |> fun vars -> Condition_closure.conditions_bound_vars vars bound_conditions
  in
  let rec loop acc = function
    | [] -> acc
    | prem :: future_prems ->
      let result =
        translate_execution_premise
          ctx
          acc.Premise_translate.env_after
          ~bound_vars:acc.Premise_translate.bound_vars_after
          ~blocked_witness_source_ids:acc.Premise_translate.blocked_witness_source_ids
          ~future_prems
          ~escape_source_ids
          origin
          prem
      in
      loop (append_execution_premise_result acc result) future_prems
  in
  let result =
    loop
      { Premise_translate.empty with
        env_after = env
      ; bound_vars_after = bound_vars
      }
      prems
  in
  { result with
    env_after =
      Expr_translate.with_condition_bound_vars
        result.Premise_translate.env_after
        result.Premise_translate.bound_vars_after
  }

let rec term_matches_general general specific =
  match general, specific with
  | Var _, _ -> true
  | Const left, Const right -> left = right
  | Qid left, Qid right -> left = right
  | App (left_name, left_args), App (right_name, right_args) ->
    left_name = right_name
    && List.length left_args = List.length right_args
    && List.for_all2 term_matches_general left_args right_args
  | _ -> false

let terms_match_general general specific =
  List.length general = List.length specific
  && List.for_all2 term_matches_general general specific

let has_else_premise prems =
  prems
  |> List.exists (fun prem ->
    match prem.it with
    | ElsePr -> true
    | _ -> false)

let without_else_premises prems =
  prems
  |> List.filter (fun prem ->
    match prem.it with
    | ElsePr -> false
    | _ -> true)

let gen_helper helper_name origin node =
  Maude_ir.generated ~provenance:(Helper helper_name) ~origin node

type enabledness_info =
  { helper_name : string
  ; output : output
  ; complement_conditions : Maude_ir.rule_condition list
  }

type enabledness_result =
  | Not_applicable
  | Enabledness of enabledness_info

let enabledness_helper_name relation_id rule_id index =
  "enabled-" ^ rule_label relation_id rule_id index

let translate_enabledness_helper
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    input_sorts
    current_lhs_terms
    index
    rule =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id.it rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      Enabledness
        { helper_name = enabledness_helper_name relation_id rule_id index
        ; output = { empty with diagnostics = hint_diags @ marker_diags }
        ; complement_conditions = []
        }
    else
      let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
      let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
      let expected_typs = input_typs @ output_typs in
      let components_opt, arity_diags =
        exp_components_match
          ctx
          origin
          "RelD/ElsePr/enabledness/arity"
          expected_typs
          exp
      in
      (match components_opt with
      | None ->
        Enabledness
          { helper_name = enabledness_helper_name relation_id rule_id index
          ; output = { empty with diagnostics = arity_diags }
          ; complement_conditions = []
          }
      | Some components ->
        let input_count = List.length input_typs in
        let rec split n left right =
          if n = 0 then List.rev left, right
          else
            match right with
            | [] -> List.rev left, []
            | item :: rest -> split (n - 1) (item :: left) rest
        in
        let input_exps, _output_exps = split input_count [] components in
        let seed =
          enabledness_helper_name relation_id rule_id index
        in
        let env, var_decls, bind_diags =
          translate_rule_binds ctx origin seed binds
        in
        let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
          lower_pattern_components ctx env origin input_exps
        in
        (match lhs_terms_opt with
        | Some lhs_terms when terms_match_general current_lhs_terms lhs_terms ->
          let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
          let premise_result =
            Premise_translate.translate_premises
              ~allow_runtime_search:true
              ctx
              env
              ~bound_conditions:lhs_guards
              ~bound_terms:lhs_terms
              origin
              (without_else_premises prems)
          in
          let helper_name = enabledness_helper_name relation_id rule_id index in
          let helper_call = app helper_name lhs_terms in
          let conditions =
            lhs_guards @ premise_result.eq_conditions
            |> Condition_closure.normalize_binding_conditions lhs_terms
            |> dedup_conditions
          in
          if premise_result.rule_conditions = [] then
            let op_decl =
              gen_helper helper_name origin
                (op helper_name (List.map sort_ref input_sorts) (sort "Bool"))
            in
            let equation =
              gen_helper helper_name origin
                (ceq helper_call (Const "true") conditions)
            in
            let admissibility_diags =
              Condition_closure.ceq_admissibility_diagnostics
                ctx
                origin
                helper_call
                (Const "true")
                conditions
            in
            let registry_diags =
              generated_statement_diagnostics ctx op_decl
              @ generated_statement_diagnostics ctx equation
            in
            Enabledness
              { helper_name
              ; output =
                  { statements = var_decls @ [ op_decl; equation ]
                  ; diagnostics =
                      hint_diags
                      @ bind_diags @ arity_diags @ lhs_diags
                      @ premise_result.diagnostics
                      @ admissibility_diags
                      @ registry_diags
                  }
              ; complement_conditions =
                  [ EqCondition
                      (BoolCond
                         (app
                            "_=/=_"
                            [ app helper_name current_lhs_terms; Const "true" ]))
                  ]
              }
          else if premise_result.runtime_truth_search_requests <> [] then
            let runtime_truth_decisions =
              premise_result.runtime_truth_search_requests
              |> List.map (fun truth_request ->
                let truth_helper_name =
                  Helper.request
                    (Context.helpers ctx)
                    { Helper.kind =
                        Helper.Runtime_predicate_truth_search truth_request
                    ; reason = Runtime_truth_search_helper.reason truth_request
                    ; origin
                    }
                in
                let decision_request =
                  { Runtime_truth_decision_helper.truth_helper_name =
                      truth_helper_name
                  ; truth_request
                  }
                in
                let decision_helper_name =
                  Helper.request
                    (Context.helpers ctx)
                    { Helper.kind =
                        Helper.Runtime_predicate_truth_decision
                          decision_request
                    ; reason =
                        Runtime_truth_decision_helper.reason
                          decision_request
                    ; origin
                    }
                in
                { Runtime_enabledness_helper.helper_name =
                    decision_helper_name
                ; request = decision_request
                })
            in
            let request =
              { Runtime_enabledness_helper.relation_id = relation_id.it
              ; rule_id = Some rule_id.it
              ; call_terms = current_lhs_terms
              ; predecessor_terms = lhs_terms
              ; input_sorts
              ; lhs_conditions = lhs_guards
              ; premise_eq_conditions = premise_result.eq_conditions
              ; premise_rule_conditions = premise_result.rule_conditions
              ; runtime_search_requests = premise_result.runtime_search_requests
              ; runtime_truth_search_requests =
                  premise_result.runtime_truth_search_requests
              ; runtime_truth_decisions
              ; source_echo = Some (Il.Print.string_of_rule rule)
              }
            in
            let runtime_helper_name =
              Helper.request
                (Context.helpers ctx)
                { Helper.kind = Helper.Runtime_enabledness request
                ; reason = Runtime_enabledness_helper.reason request
                ; origin
                }
            in
            Enabledness
              { helper_name = runtime_helper_name
              ; output =
                  { statements = var_decls
                  ; diagnostics =
                      hint_diags
                      @ bind_diags @ arity_diags @ lhs_diags
                      @ premise_result.diagnostics
                  }
              ; complement_conditions =
                  [ Runtime_enabledness_helper.false_rewrite_condition
                      ~helper_name:runtime_helper_name
                      request
                  ]
              }
          else
            Enabledness
              { helper_name
              ; output =
                  { statements = var_decls
                  ; diagnostics =
                      hint_diags
                      @ bind_diags @ arity_diags @ lhs_diags
                      @ premise_result.diagnostics
                      @ [ unsupported
                            ~ctx
                            ~origin
                            ~constructor:"RelD/ElsePr/enabledness/rewrite-condition"
                            ~source_echo:(Il.Print.string_of_rule rule)
                            ~reason:
                              "enabledness helper for an otherwise predecessor contains rewrite conditions that are not runtime truth-search decisions"
                            ~suggestion:
                              "Keep this otherwise complement Unsupported until this rewrite-dependent premise shape has a source-complete enabledness decision helper"
                            ()
                        ]
                  }
              ; complement_conditions = []
              }
        | Some _ -> Not_applicable
        | None ->
          Enabledness
            { helper_name = enabledness_helper_name relation_id rule_id index
            ; output =
                { statements = var_decls
                ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
                }
            ; complement_conditions = []
            }))

let else_complement
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    shape
    input_sorts
    origin
    current_lhs_terms
    previous_rules =
  let enabledness =
    previous_rules
    |> List.mapi (fun index rule ->
      translate_enabledness_helper
        ctx
        rel_origin
        relation_id
        relation_kind
        relation_mixop
        shape
        input_sorts
        current_lhs_terms
        (index + 1)
        rule)
  in
  let applicable =
    enabledness
    |> List.filter_map (function
      | Not_applicable -> None
      | Enabledness result -> Some result)
  in
  match applicable with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"RelD/RuleD/ElsePr/complement"
            ~reason:
              "source otherwise rule has no earlier rule with the same relation input skeleton, so the translator cannot derive a source enabledness complement"
            ~suggestion:
              "Keep this ElsePr Unsupported until rule grouping/preprocessing can prove the relevant predecessor rules"
            ()
        ]
    },
    []
  | _ ->
    let statements =
      applicable
      |> List.map (fun result -> result.output.statements)
      |> List.concat
    in
    let diagnostics =
      applicable
      |> List.map (fun result -> result.output.diagnostics)
      |> List.concat
    in
    let has_blocking = has_fatal diagnostics in
    let statements =
      if has_blocking then
        []
      else
        statements
    in
    let complement_conditions =
      if has_blocking then
        []
      else
        applicable
        |> List.map (fun result -> result.complement_conditions)
        |> List.concat
    in
    let diagnostics =
      if has_blocking then
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"RelD/RuleD/ElsePr/complement-unsupported"
            ~reason:
              "at least one predecessor rule in this otherwise group needs enabledness conditions that are not safely expressible by the current source-derived helper slice; the predecessor rule itself reports the blocking premise"
            ~suggestion:
              "Leave this ElsePr Unsupported until the blocking predecessor premise shape has a documented helper"
            ()
        ]
      else
        diagnostics
    in
    { statements; diagnostics }, complement_conditions

let rec premise_has_execution_dependency ctx prem =
  match prem.it with
  | RulePr (rel_id, _, _, _) ->
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | Some relation ->
      (match
         (Relation_shape.of_relation relation).Relation_shape.decision
       with
      | Relation_shape.Execution _ ->
        not (Analysis.Function_graph.relation_has_maude_equational_view relation)
      | Relation_shape.Static_validation _
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Unknown _ -> false)
    | None -> false)
  | IterPr (prem, _) | NegPr prem -> premise_has_execution_dependency ctx prem
  | IfPr _ | LetPr _ | ElsePr -> false

let deterministic_rewrite_dependency_diagnostics ctx rel_origin rules =
  rules
  |> List.mapi (fun index rule ->
    let origin = rule_origin rel_origin (index + 1) rule in
    match rule.it with
    | RuleD (_, _, _, _, prems)
      when List.exists (premise_has_execution_dependency ctx) prems ->
      [ unsupported
          ~ctx
          ~origin
          ~constructor:"RelD/deterministic/rewrite-premise"
          ~source_echo:(Il.Print.string_of_rule rule)
          ~reason:
            "deterministic relation lowering cannot emit an equation for a rule whose premise depends on an execution rewrite relation"
          ~suggestion:
            "Use a rewrite-dependent helper/crl lowering for this source rule; do not put rewrite conditions inside ceq/cmb"
          ()
      ]
    | _ -> [])
  |> List.concat

let translate_deterministic_rule
    ctx
    rel_origin
    op_name
    id
    relation_kind
    relation_mixop
    (shape : Relation_shape.deterministic_shape)
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin id.it rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      { empty with diagnostics = hint_diags @ marker_diags }
    else
    let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
    let _output_typ = shape.Relation_shape.output.typ in
    let expected_typs = input_typs @ [ _output_typ ] in
    let components_opt, arity_diags =
      exp_components_match ctx origin "RelD/deterministic/RuleD/arity" expected_typs exp
    in
    let seed = Naming.sanitize id.it ^ "-rule-" ^ string_of_int index in
    let env, var_decls, bind_diags =
      translate_rule_binds ctx origin seed binds
    in
    (match components_opt with
    | None ->
      { statements = var_decls
      ; diagnostics = hint_diags @ bind_diags @ arity_diags
      }
    | Some components ->
      let input_exps, output_exp =
        match List.rev components with
        | output :: reversed_inputs -> List.rev reversed_inputs, output
        | [] -> [], exp
      in
      let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
        lower_pattern_components ctx env origin input_exps
      in
      (match lhs_terms_opt with
      | None ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
        }
      | Some lhs_terms ->
        let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
        let premise_result =
          Premise_translate.translate_premises
            ctx
            env
            ~bound_conditions:lhs_guards
            ~escape_source_ids:(Premise_capture.source_and_note_free_var_ids output_exp)
            ~bound_terms:lhs_terms
            origin
            prems
        in
        let rhs_result =
          Expr_translate.lower_value ctx premise_result.env_after origin output_exp
        in
        let diagnostics =
          hint_diags
          @ bind_diags @ arity_diags @ lhs_diags @ premise_result.diagnostics
          @ rhs_result.diagnostics
        in
        if has_fatal diagnostics then
          { statements = var_decls; diagnostics }
        else
          match rhs_result.term with
          | None -> { statements = var_decls; diagnostics }
          | Some rhs_term ->
            let lhs = relation_call op_name lhs_terms in
            let attrs = if premise_result.has_else then [ Owise ] else [] in
            let conditions =
              lhs_guards @ premise_result.eq_conditions @ rhs_result.guards
              |> Condition_closure.normalize_binding_conditions lhs_terms
              |> dedup_conditions
            in
            let admissibility_diags =
              Condition_closure.ceq_admissibility_diagnostics
                ctx
                origin
                lhs
                rhs_term
                conditions
            in
            if has_fatal admissibility_diags then
              { statements = var_decls; diagnostics = diagnostics @ admissibility_diags }
            else
              { statements =
                  var_decls
                  @ [ gen origin (ceq lhs rhs_term conditions ~attrs) ]
              ; diagnostics
              }))

let translate_deterministic
    ctx
    origin
    id
    relation_kind
    relation_mixop
    (shape : Relation_shape.deterministic_shape)
    rules
  =
  let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
  let output_typ = shape.Relation_shape.output.typ in
    let rewrite_dependency_diags =
      deterministic_rewrite_dependency_diagnostics ctx origin rules
    in
    if has_fatal rewrite_dependency_diags then
      { empty with diagnostics = rewrite_dependency_diags }
    else
    let input_sorts_opt, input_diags =
      component_sorts ctx origin "RelD/deterministic/input" input_typs
    in
    let output_sort_opt, output_diags =
      component_sort ctx origin "RelD/deterministic/output" output_typ
    in
    let diagnostics = input_diags @ output_diags in
    if has_fatal diagnostics then
      { empty with diagnostics }
    else
      match input_sorts_opt, output_sort_opt with
      | Some input_sorts, Some output_sort ->
        let op_name = Naming.relation_op id in
        let op_decl =
          gen origin
            (op
               op_name
               (List.map sort_ref input_sorts)
               output_sort)
        in
        let rules_output =
          rules
          |> List.mapi (fun index rule ->
            translate_deterministic_rule
              ctx
              origin
              op_name
              id
              relation_kind
              relation_mixop
              shape
              (index + 1)
              rule)
          |> List.fold_left append empty
        in
        { statements = op_decl :: rules_output.statements
        ; diagnostics = diagnostics @ rules_output.diagnostics
        }
      | _ -> { empty with diagnostics }

let translate_execution_rule
    ctx
    rel_origin
    op_name
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    input_sorts
    output_sorts
    previous_rules
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id.it rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      { empty with diagnostics = hint_diags @ marker_diags }
    else
    let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
    let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
    let expected_typs = input_typs @ output_typs in
    let components_opt, arity_diags =
      exp_components_match ctx origin "RelD/execution/RuleD/arity" expected_typs exp
    in
    let seed = op_name ^ "-rule-" ^ string_of_int index in
    let env, var_decls, bind_diags =
      translate_rule_binds ctx origin seed binds
    in
    (match components_opt with
    | None ->
      { statements = var_decls
      ; diagnostics = hint_diags @ bind_diags @ arity_diags
      }
    | Some components ->
      let input_count = List.length input_typs in
      let rec split n left right =
        if n = 0 then List.rev left, right
        else
          match right with
          | [] -> List.rev left, []
          | item :: rest -> split (n - 1) (item :: left) rest
      in
      let input_exps, output_exps = split input_count [] components in
      let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
        lower_pattern_components ctx env origin input_exps
      in
      (match lhs_terms_opt with
      | Some lhs_terms ->
        let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
        let has_else = has_else_premise prems in
        let else_output, else_conditions =
          if has_else then
            else_complement
              ctx
              rel_origin
              relation_id
              relation_kind
              relation_mixop
              shape
              input_sorts
              origin
              lhs_terms
              previous_rules
          else
            empty, []
        in
        let premise_result =
          translate_execution_premises
            ctx
            env
            ~bound_conditions:lhs_guards
            ~escape_source_ids:
              (output_exps
               |> List.concat_map Premise_capture.source_and_note_free_var_ids
               |> List.sort_uniq String.compare)
            ~bound_terms:lhs_terms
            origin
            (without_else_premises prems)
        in
        let output_terms_opt, output_guards, output_diags =
          lower_value_components
            ctx
            premise_result.env_after
            origin
            "rhs"
            output_exps
        in
        let diagnostics =
          hint_diags
          @ bind_diags @ arity_diags @ lhs_diags @ output_diags
          @ else_output.diagnostics @ premise_result.diagnostics
        in
        if has_fatal diagnostics then
          { statements = var_decls @ else_output.statements; diagnostics }
        else
          (match output_terms_opt with
          | Some output_terms
            when List.length output_terms = List.length output_sorts ->
            let rhs_term = tuple_carrier output_sorts output_terms in
            let lhs = relation_call op_name lhs_terms in
            let conditions =
              List.map (fun condition -> EqCondition condition) lhs_guards
              @ else_conditions
              @ premise_result.rule_conditions
              @ List.map (fun condition -> EqCondition condition) output_guards
              |> Condition_closure.normalize_rule_conditions [ lhs ]
              |> dedup_rule_conditions
            in
            let admissibility_diags =
              Condition_closure.crl_admissibility_diagnostics
                ctx
                origin
                lhs
                rhs_term
                conditions
            in
            if has_fatal admissibility_diags then
              { statements = var_decls
              ; diagnostics = diagnostics @ admissibility_diags
              }
            else
              let statement =
                gen origin
                  (crl
                     ~label:(rule_label relation_id rule_id index)
                     lhs
                     rhs_term
                     conditions)
              in
              let registry_diags =
                generated_statement_diagnostics ctx statement
              in
              if has_fatal registry_diags then
                { statements = []
                ; diagnostics = diagnostics @ registry_diags
                }
              else
                { statements = var_decls @ else_output.statements @ [ statement ]
                ; diagnostics
                }
          | Some _ ->
            { statements = var_decls @ else_output.statements
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/execution/output"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "execution relation lowering currently supports exactly one output component; multi-output execution rules remain Unsupported"
                      ()
                  ]
            }
          | None -> { statements = var_decls @ else_output.statements; diagnostics })
      | _ ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
        }))
let translate_execution
    ctx
    origin
    id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    rules
  =
  let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
  let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
    let input_sorts_opt, input_diags =
      component_sorts ctx origin "RelD/execution/input" input_typs
    in
    let output_sorts_opt, output_diags =
      component_sorts ctx origin "RelD/execution/output" output_typs
    in
    let diagnostics = input_diags @ output_diags in
    if has_fatal diagnostics then
      { empty with diagnostics }
    else
      match input_sorts_opt, output_sorts_opt with
      | Some input_sorts, Some output_sorts ->
        let op_name = Naming.relation_op id in
        let conf_sort = relation_conf_sort id in
        let output_sort = execution_output_sort output_sorts in
        let header =
          [ gen origin (sort_decl conf_sort)
          ; gen origin (subsort output_sort conf_sort)
          ; gen origin
              (op
                 ~attrs:(frozen_all (List.length input_sorts))
                 op_name
                 (List.map sort_ref input_sorts)
                 conf_sort)
          ]
        in
        let rules_output =
          let rec loop previous index = function
            | [] -> empty
            | rule :: rest ->
              let current =
                translate_execution_rule
                  ctx
                  origin
                  op_name
                  id
                  relation_kind
                  relation_mixop
                  shape
                  input_sorts
                  output_sorts
                  previous
                  index
                  rule
              in
              append current (loop (previous @ [ rule ]) (index + 1) rest)
          in
          loop [] 1 rules
        in
        { statements = header @ dedup_generated rules_output.statements
        ; diagnostics = diagnostics @ rules_output.diagnostics
        }
      | _ -> { empty with diagnostics }

let translate_runtime_predicate_rule
    ctx
    rel_origin
    op_name
    relation_id
    relation_kind
    relation_mixop
    components
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      { empty with diagnostics = hint_diags @ marker_diags }
    else
      let expected_typs = Relation_shape.component_typs components in
      let components_opt, arity_diags =
        exp_components_match ctx origin "RelD/runtime-predicate/RuleD/arity" expected_typs exp
      in
      let seed = op_name ^ "-predicate-rule-" ^ string_of_int index in
      let env, var_decls, bind_diags =
        translate_rule_binds ctx origin seed binds
      in
      (match components_opt with
      | None ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags
        }
      | Some body_components ->
        let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
          lower_pattern_components ctx env origin body_components
        in
        (match lhs_terms_opt with
        | None ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
        }
        | Some lhs_terms ->
          let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
          let premise_result =
            Premise_translate.translate_premises
              ctx
              env
              ~bound_conditions:lhs_guards
              ~escape_source_ids:(Premise_capture.source_and_note_free_var_ids exp)
              ~bound_terms:lhs_terms
              origin
              prems
          in
          let diagnostics =
            hint_diags
            @ bind_diags @ arity_diags @ lhs_diags @ premise_result.diagnostics
          in
          if premise_result.rule_conditions <> [] then
            { statements = var_decls
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/runtime-predicate/rewrite-premise"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "runtime predicate RelD rules cannot use rewrite conditions in this helper-free slice"
                      ~suggestion:
                        "Promote the enclosing predicate/definition to a rewrite-dependent helper before lowering this rule"
                      ()
                  ]
            }
          else if premise_result.has_else then
            { statements = var_decls
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/runtime-predicate/ElsePr"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "runtime predicate ElsePr requires a proven executable/decidable complement before [owise] can be used soundly"
                      ~suggestion:
                        "Keep this source otherwise branch Unsupported until a source-derived predicate complement or total false fallback is implemented"
                      ()
                  ]
            }
          else if has_fatal diagnostics then
            { statements = var_decls; diagnostics }
          else
            let lhs = relation_call op_name lhs_terms in
            let conditions =
              lhs_guards @ premise_result.eq_conditions
              |> Condition_closure.normalize_binding_conditions lhs_terms
              |> dedup_conditions
            in
            let admissibility_diags =
              Condition_closure.ceq_admissibility_diagnostics
                ctx
                origin
                lhs
                (Const "true")
                conditions
            in
            if has_fatal admissibility_diags then
              { statements = var_decls; diagnostics = diagnostics @ admissibility_diags }
            else
              { statements =
                  var_decls
                  @ [ gen origin (ceq lhs (Const "true") conditions) ]
              ; diagnostics
              }))

let runtime_predicate_blocker_text
    (blocker : Analysis.Function_graph.runtime_search_blocker)
  =
  let rule =
    match blocker.Analysis.Function_graph.rule_id with
    | None -> ""
    | Some rule_id -> "/" ^ rule_id
  in
  let premise =
    match
      ( blocker.Analysis.Function_graph.premise_constructor
      , blocker.Analysis.Function_graph.premise_source_echo )
    with
    | None, None -> ""
    | Some constructor, None -> " via " ^ constructor
    | None, Some source -> " via premise `" ^ source ^ "`"
    | Some constructor, Some source -> " via " ^ constructor ^ " `" ^ source ^ "`"
  in
  Printf.sprintf
    "%s%s%s [%s]: %s"
    blocker.Analysis.Function_graph.relation_id
    rule
    premise
    blocker.Analysis.Function_graph.constructor
    blocker.Analysis.Function_graph.reason

let format_runtime_predicate_blockers blockers =
  let rec take n values =
    match n, values with
    | 0, rest -> [], List.length rest
    | _, [] -> [], 0
    | n, value :: rest ->
      let kept, omitted = take (n - 1) rest in
      value :: kept, omitted
  in
  let kept, omitted = take 8 (List.map runtime_predicate_blocker_text blockers) in
  let rendered = String.concat "; " kept in
  if omitted = 0 then rendered
  else if rendered = "" then Printf.sprintf "... and %d more" omitted
  else Printf.sprintf "%s; ... and %d more" rendered omitted

let runtime_predicate_dependency_diagnostics ctx origin id =
  match
    Analysis.Function_graph.runtime_predicate_dependency_completeness
      (Context.function_graph ctx)
      id.it
  with
  | Analysis.Function_graph.Runtime_predicate_dependencies_complete _ -> []
  | Analysis.Function_graph.Runtime_predicate_dependencies_incomplete
      { closure; blockers; _ } ->
    [ unsupported
        ~ctx
        ~origin
        ~constructor:"RelD/runtime-predicate/incomplete-dependency"
        ~reason:
          ("runtime predicate relation depends on runtime-demanded predicate relation(s) whose source predicate closure is not complete; dependency closure: "
           ^ String.concat " -> " closure
           ^ "; blockers: "
           ^ format_runtime_predicate_blockers blockers)
        ~suggestion:
          "Emit only the predicate op until every runtime predicate dependency can be lowered source-completely; partial true equations would turn missing source branches into false Maude results"
        ()
    ]

let source_rule_of_runtime_search_rule
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  { Runtime_witness_proof.relation_id = rule.relation_id
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; source_echo = rule.source_echo
  ; head = rule.head
  ; prems = rule.prems
  }

let rule_has_transitive_witness_domain rule =
  rule
  |> source_rule_of_runtime_search_rule
  |> Runtime_witness_proof.transitive_domain
  |> Option.is_some

let rule_has_target_guided_witness rule =
  rule
  |> source_rule_of_runtime_search_rule
  |> Runtime_witness_proof.target_chain
  |> Option.is_some

let runtime_predicate_needs_truth_search ctx id =
  match
    Analysis.Function_graph.runtime_predicate_search_plan
      (Context.function_graph ctx)
      id.it
  with
  | Analysis.Function_graph.Runtime_search_no_shape_blockers { rules; _ }
  | Analysis.Function_graph.Runtime_search_blocked_plan { rules; _ } ->
    List.exists
      (fun rule ->
        rule_has_transitive_witness_domain rule
        || rule_has_target_guided_witness rule)
      rules

let runtime_predicate_truth_search_deferred ctx origin id =
  skipped
    ~ctx
    ~origin
    ~constructor:"RelD/runtime-predicate/truth-search-deferred"
    ~reason:
      "runtime predicate relation has a source recursive witness rule; emitting only some Bool ceq true branches would make missing source branches look false in Maude"
    ~suggestion:
      "Represent this predicate through a source-complete rewrite-backed truth-search helper before using it in runtime premises"
    ~source_echo:("RelD " ^ id.it)
    ()

let translate_runtime_predicate
    ctx origin id relation_kind relation_mixop runtime_reason components rules =
  let typs = Relation_shape.component_typs components in
  let input_sorts_opt, input_diags =
    component_sorts ctx origin "RelD/runtime-predicate/input" typs
  in
  if has_fatal input_diags then
    { empty with diagnostics = input_diags }
  else
    match input_sorts_opt with
    | Some input_sorts ->
      let op_name = Naming.relation_op id in
      let op_decl =
        gen origin
          (op
             op_name
             (List.map sort_ref input_sorts)
             (sort "Bool"))
      in
      let dependency_diags =
        runtime_predicate_dependency_diagnostics ctx origin id
      in
      if runtime_predicate_needs_truth_search ctx id then
        { statements = [ op_decl ]
        ; diagnostics =
            input_diags @ dependency_diags
            @ [ runtime_predicate_truth_search_deferred ctx origin id ]
        }
      else
        let rules_output =
          rules
          |> List.mapi (fun index rule ->
            translate_runtime_predicate_rule
              ctx
              origin
              op_name
              id.it
              relation_kind
              relation_mixop
              components
              (index + 1)
              rule)
          |> List.fold_left append empty
        in
        let diagnostics =
          input_diags @ dependency_diags @ rules_output.diagnostics
        in
        let statements =
          if has_fatal diagnostics then
            [ op_decl ]
          else
            op_decl :: rules_output.statements
        in
        { statements; diagnostics }
    | None ->
      { empty with
        diagnostics =
          input_diags
          @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"RelD/runtime-predicate"
                ~reason:
                  (runtime_reason
                   ^ "; runtime predicate relation arguments could not be assigned Maude carriers")
                ~suggestion:
                  "Add source-preserving carrier support before emitting this runtime predicate relation"
                ()
            ]
      }

let translate ctx origin id params mixop result_typ rules =
  let relation_shape = Relation_shape.of_reld params mixop result_typ in
  let relation_kind = relation_shape.Relation_shape.marker in
  let relation_kind_text = relation_shape.Relation_shape.marker_text in
  if params <> [] then
    one_diagnostic
      (unsupported
         ~ctx
         ~origin
         ~constructor:"RelD/params"
         ~reason:
           ("relation `"
            ^ id.it
            ^ "` has source parameters `"
            ^ Il.Print.string_of_params params
            ^ "`, but parameterized relation lowering is not implemented yet")
         ~suggestion:
           "Preserve this RelD as Unsupported until RulePr argument instantiation and relation specialization/tag lowering are designed source-completely"
         ())
  else
  match relation_shape.Relation_shape.decision with
  | Relation_shape.Static_validation _ ->
    (match
       Analysis.Function_graph.relation_runtime_demand_reason
         (Context.function_graph ctx)
         id.it
     with
    | Some runtime_reason ->
      translate_runtime_predicate
        ctx
        origin
        id
        relation_kind
        mixop
        runtime_reason
        relation_shape.Relation_shape.components
        rules
    | None ->
      one_diagnostic
        (skipped
           ~ctx
           ~origin
           ~constructor:"RelD/static-validation"
           ~reason:
             ("static validation predicate relation is discharged by the official validator in Runtime_after_external_validation; structural relation classification is "
              ^ relation_kind_text)
           ~suggestion:
             "Keep the source relation in diagnostics/metadata; emit no runtime Maude statements for this validation-only RelD"
           ()))
  | Relation_shape.Runtime_predicate runtime_reason ->
    translate_runtime_predicate
      ctx
      origin
      id
      relation_kind
      mixop
      runtime_reason
      relation_shape.Relation_shape.components
      rules
  | Relation_shape.Deterministic_candidate shape ->
    translate_deterministic ctx origin id relation_kind mixop shape rules
  | Relation_shape.Execution shape ->
    if Reld_equational_view.relation_has_maude_equational_view ctx id then
      Reld_equational_view.translate ctx origin id shape rules
    else
      translate_execution ctx origin id relation_kind mixop shape rules
  | Relation_shape.Unknown reason ->
    one_diagnostic
      (unsupported
         ~ctx
         ~origin
         ~constructor:"RelD"
         ~reason:
           ("RelD marker is not classified as validation, deterministic, or execution; structural relation classification is "
            ^ relation_kind_text
            ^ "; "
            ^ reason)
         ~suggestion:
           "Classify this relation structurally before deciding whether to skip or lower it"
         ())
