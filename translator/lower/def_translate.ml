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
    ?suggestion ?source_echo
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
    ~ctx ~origin ~constructor ~reason ()

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
    ~ctx ~origin ~constructor ~reason ()

let obligation ?suggestion ~ctx ~origin ~constructor ~reason () =
  diagnostic
    ?suggestion
    ?source_echo:(source_echo origin)
    ~category:Diagnostics.Obligation
    ~ctx ~origin ~constructor ~reason ()

let one_diagnostic diagnostic =
  { empty with diagnostics = [ diagnostic ] }

let has_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let dedup_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let gen origin node =
  Maude_ir.generated ~origin node

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let origin_for_def path ordinal def =
  let constructor = Analysis.constructor_of_def def in
  let id_suffix =
    match Analysis.id_of_def def with
    | None -> ""
    | Some id -> "-" ^ Naming.sanitize id
  in
  let segment = Printf.sprintf "%04d-%s%s" ordinal constructor id_suffix in
  Origin.make
    ~source_echo:(Analysis.source_echo_of_def def)
    ~path:(path @ [ segment ])
    ~ast_constructor:constructor def.Util.Source.at

let hintdef_parts hintdef =
  match hintdef.it with
  | TypH (id, hints) -> "TypH", id, hints
  | RelH (id, hints) -> "RelH", id, hints
  | DecH (id, hints) -> "DecH", id, hints
  | GramH (id, hints) -> "GramH", id, hints

let translate_hintdef ctx origin hintdef =
  let hintdef_constructor, target_id, hints = hintdef_parts hintdef in
  let ctx = Context.with_def ctx target_id.it in
  match hints with
  | [] ->
    one_diagnostic
      (skipped
         ~ctx ~origin ~constructor:hintdef_constructor
         ~reason:"empty HintD carries no runtime Maude statement but its origin is recorded"
         ())
  | _ ->
    hints
    |> List.map (fun hint ->
      let hint_name = hint.hintid.it in
      let constructor = hintdef_constructor ^ "/hint(" ^ hint_name ^ ")" in
      match Analysis.Hint_policy.classify hint with
      | Presentation ->
        skipped
          ~ctx ~origin ~constructor
          ~reason:"presentation hint has no runtime rewrite meaning in Runtime_after_external_validation"
          ~suggestion:"Keep the hint in diagnostics/metadata rather than emitting a Maude statement"
          ()
      | Semantic_obligation ->
        obligation
          ~ctx ~origin ~constructor
          ~reason:
            "semantic hint metadata is recorded as an external prelude/builtin obligation in this scaffold"
          ~suggestion:
            "Implement the corresponding prelude/builtin contract before generated code depends on this hint"
          ()
      | Translator_annotation ->
        skipped
          ~ctx ~origin ~constructor
          ~reason:
            "translator annotation has been consumed by analysis and emits no runtime Maude statement"
          ~suggestion:
            "Keep the annotation in source/provenance metadata; do not turn it into a Maude equation"
          ()
      | Unknown ->
        unsupported
          ~ctx ~origin ~constructor
          ~reason:"hint classification is unknown, so the translator refuses to erase it silently"
          ~suggestion:"Classify the hint as presentation metadata, semantic obligation, or a documented unsupported case"
          ())
    |> fun diagnostics -> { empty with diagnostics }

type decd_param_lowering =
  | Runtime_param of sort
  | Static_typ_param of Analysis.Function_graph.static_typ_binding
  | Static_def_param of Analysis.Function_graph.static_def_binding
  | Unsupported_param

let unsupported_static_typ_param ctx origin param =
  unsupported
    ~ctx ~origin ~constructor:"DecD/param/TypP"
    ~source_echo:(Il.Print.string_of_param param)
    ~reason:
      "compile-time syntax parameter cannot be erased from DecD without collapsing distinct source specializations"
    ~suggestion:
      "Implement finite TypP/TypA monomorphization and emit deterministic specialized operators for this DecD"
    ()

let unsupported_static_param ctx origin param =
  unsupported
    ~ctx ~origin ~constructor:"DecD/param/static"
    ~reason:
      ("static parameter `" ^ Il.Print.string_of_param param
       ^ "` requires monomorphization before DecD lowering")
    ~suggestion:"Implement finite static specialization before lowering this DecD"
    ()

let unsupported_type ctx origin constructor typ =
  unsupported
    ~ctx ~origin ~constructor
    ~reason:
      ("unsupported DecD carrier type `" ^ Il.Print.string_of_typ typ ^ "`")
    ~suggestion:"Add a source-preserving carrier/witness encoding for this type before lowering the DecD"
    ()

let static_typ_binding_for_param ctx origin param =
  match param.it with
  | TypP id ->
    (match Context.current_specialization ctx with
    | None -> None, [ unsupported_static_typ_param ctx origin param ]
    | Some specialization ->
      (match
         List.find_opt
           (fun (binding : Analysis.Function_graph.static_typ_binding) ->
             binding.param_id = id.it)
           specialization.static_typs
       with
      | Some binding -> Some binding, []
      | None -> None, [ unsupported_static_typ_param ctx origin param ]))
  | ExpP _ | DefP _ | GramP _ -> None, []

let static_def_binding_for_param ctx origin param =
  match param.it with
  | DefP (id, _, _) ->
    (match Context.current_specialization ctx with
    | None -> None, [ unsupported_static_param ctx origin param ]
    | Some specialization ->
      (match
         List.find_opt
           (fun (binding : Analysis.Function_graph.static_def_binding) ->
             binding.param_id = id.it)
           specialization.static_defs
       with
      | Some binding -> Some binding, []
      | None -> None, [ unsupported_static_param ctx origin param ]))
  | ExpP _ | TypP _ | GramP _ -> None, []

let decd_param_lowering ctx origin param =
  match param.it with
  | ExpP (_, typ) ->
    (match Expr_translate.carrier_sort_of_typ typ with
    | Some sort -> Runtime_param sort, []
    | None -> Unsupported_param, [ unsupported_type ctx origin "DecD/param/ExpP" typ ])
  | TypP _ ->
    (match static_typ_binding_for_param ctx origin param with
    | Some binding, diagnostics -> Static_typ_param binding, diagnostics
    | None, diagnostics -> Unsupported_param, diagnostics)
  | DefP _ ->
    (match static_def_binding_for_param ctx origin param with
    | Some binding, diagnostics -> Static_def_param binding, diagnostics
    | None, diagnostics -> Unsupported_param, diagnostics)
  | GramP _ ->
    Unsupported_param, [ unsupported_static_param ctx origin param ]

let decd_result_sort ctx origin typ =
  match Expr_translate.carrier_sort_of_typ typ with
  | Some sort -> Some sort, []
  | None -> None, [ unsupported_type ctx origin "DecD/result" typ ]

let maude_var_of_bind seed index id =
  if id.it = "_" then
    Naming.maude_var (seed ^ "-wild-" ^ string_of_int index)
  else
    Naming.maude_var (seed ^ "-" ^ string_of_int index ^ "-" ^ id.it)

let translate_exp_bind ctx origin seed index env bind =
  match bind.it with
  | ExpB (id, typ) ->
    if id.it = "_" then
      env, [], 
      [ unsupported
          ~ctx ~origin ~constructor:"DecD/DefD/ExpB"
          ~reason:"wildcard ExpB bind cannot be referenced safely in generated equation scope"
          ~suggestion:"Implement anonymous pattern bind handling before lowering this clause"
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
        env, [],
        [ unsupported_type ctx origin "DecD/DefD/ExpB" typ ])
  | TypB id ->
    if Context.find_static_typ ctx id.it <> None then
      env, [],
      [ skipped
          ~ctx ~origin ~constructor:"DecD/DefD/bind/TypB"
          ~source_echo:(Il.Print.string_of_bind bind)
          ~reason:
            "compile-time syntax binder is already fixed by the current TypP/TypA specialization and has no runtime Maude variable"
          ~suggestion:
            "Keep the binder origin in diagnostics; do not emit it as a runtime argument"
          ()
      ]
    else
      env, [],
      [ unsupported
          ~ctx ~origin ~constructor:"DecD/DefD/bind/TypB"
          ~source_echo:(Il.Print.string_of_bind bind)
          ~reason:
            "compile-time syntax binder is not bound by the current specialization, so erasing it would collapse source structure"
          ~suggestion:
            "Extend finite monomorphization to introduce this local static binder before lowering the clause"
          ()
      ]
  | DefB (id, _, _) ->
    if Context.find_static_def ctx id.it <> None then
      env, [],
      [ skipped
          ~ctx ~origin ~constructor:"DecD/DefD/bind/DefB"
          ~source_echo:(Il.Print.string_of_bind bind)
          ~reason:
            "compile-time definition binder is already fixed by the current DefP/DefA specialization and has no runtime Maude variable"
          ~suggestion:
            "Keep the binder origin in diagnostics; do not emit it as a runtime argument"
          ()
      ]
    else
      env, [],
      [ unsupported
          ~ctx ~origin ~constructor:"DecD/DefD/static-bind"
          ~source_echo:(Il.Print.string_of_bind bind)
          ~reason:
            "local definition static clause bind is not bound by the current specialization"
          ~suggestion:"Specialize the enclosing DecD before lowering this clause"
          ()
      ]
  | GramB _ ->
    env, [],
    [ unsupported
        ~ctx ~origin ~constructor:"DecD/DefD/static-bind"
        ~reason:"definition/grammar static clause binds require monomorphization and are outside pure DecD lowering"
        ~suggestion:"Specialize the enclosing DecD before lowering this clause"
        ()
    ]

let translate_clause_binds ctx origin seed binds =
  binds
  |> List.mapi (fun index bind -> index + 1, bind)
  |> List.fold_left
       (fun (env, statements, diagnostics) (index, bind) ->
         let env, new_statements, new_diagnostics =
           translate_exp_bind ctx origin seed index env bind
         in
         env, statements @ new_statements, diagnostics @ new_diagnostics)
       (Expr_translate.empty_env, [], [])

let unsupported_clause_arg ctx origin constructor arg reason =
  unsupported
    ~ctx ~origin ~constructor
    ~source_echo:(Il.Print.string_of_arg arg)
    ~reason
    ~suggestion:"Specialize the enclosing DecD before lowering this clause"
    ()

type clause_arg_result =
  { arg_term : Maude_ir.term option
  ; arg_guards : Maude_ir.eq_condition list
  ; arg_bindings : (string * Expr_translate.binding) list
  ; arg_diagnostics : Diagnostics.t list
  }

let clause_arg_from_pattern (result : Expr_translate.pattern_result) =
  { arg_term = result.pattern_term
  ; arg_guards = result.pattern_guards
  ; arg_bindings = result.introduced_bindings
  ; arg_diagnostics = result.pattern_diagnostics
  }

let clause_arg_none diagnostics =
  { arg_term = None; arg_guards = []; arg_bindings = []; arg_diagnostics = diagnostics }

let translate_clause_arg ctx env origin param arg =
  match param, arg.it with
  | Runtime_param _, ExpA exp ->
    let exp_origin =
      child_origin origin "lhs-arg" "Expr" exp.at (Some (Il.Print.string_of_exp exp))
    in
    Expr_translate.lower_pattern_with_bindings ctx env exp_origin exp
    |> clause_arg_from_pattern
  | Runtime_param _, (TypA _ | DefA _ | GramA _) ->
    clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/runtime-arg"
            arg
            "runtime DecD parameter position received a static clause argument"
        ]
  | Static_typ_param expected, TypA typ ->
    let actual_key =
      Analysis.Function_graph.typ_static_key_with_env (Context.static_typ_env ctx) typ
    in
    if actual_key = Some expected.key then
      clause_arg_none []
    else
      clause_arg_none
          [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/TypA"
              arg
              ("static clause argument does not match current specialization key `"
               ^ expected.key ^ "`")
          ]
  | Static_typ_param _, (ExpA _ | DefA _ | GramA _) ->
    clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/TypP"
            arg
            "TypP parameter position requires a TypA clause argument in this specialization slice"
        ]
  | Static_def_param expected, DefA actual_id ->
    let resolved_actual_id =
      match Context.find_static_def ctx actual_id.it with
      | Some target_id -> target_id
      | None -> actual_id.it
    in
    if resolved_actual_id = expected.target_id then
      clause_arg_none []
    else
      clause_arg_none
          [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/DefA"
              arg
              ("static definition clause argument does not match current specialization target `"
               ^ expected.target_id ^ "`")
          ]
  | Static_def_param _, (ExpA _ | TypA _ | GramA _) ->
    clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/DefP"
            arg
            "DefP parameter position requires a DefA clause argument in this specialization slice"
        ]
  | Unsupported_param, _ ->
    clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg"
            arg
            "clause argument belongs to an unsupported static parameter kind"
        ]

let runtime_param_count params =
  params
  |> List.fold_left
       (fun count -> function
         | Runtime_param _ -> count + 1
         | Static_typ_param _ -> count
         | Static_def_param _ -> count
         | Unsupported_param -> count)
       0

let translate_clause_args ctx env origin params args =
  if List.length params <> List.length args then
    None,
    env,
    [],
    [ unsupported
        ~ctx ~origin ~constructor:"DecD/DefD/arity"
        ~reason:
          (Printf.sprintf
             "clause has %d argument(s), but enclosing DecD has %d parameter(s); static TypP erasure still requires source-level arity alignment"
             (List.length args)
             (List.length params))
        ~suggestion:"Preserve source argument positions or implement full static specialization before lowering this clause"
        ()
    ]
  else
  let results = List.map2 (translate_clause_arg ctx env origin) params args in
  let terms = List.filter_map (fun result -> result.arg_term) results in
  let guards = List.concat (List.map (fun result -> result.arg_guards) results) in
  let bindings = List.concat (List.map (fun result -> result.arg_bindings) results) in
  let diagnostics =
    List.concat (List.map (fun result -> result.arg_diagnostics) results)
  in
  let lhs_bound_vars =
    Condition_closure.conditions_bound_vars
      (terms
       |> List.map Condition_closure.term_vars
       |> List.concat
       |> List.sort_uniq String.compare)
      guards
  in
  let env_after =
    bindings
    |> List.fold_left
         (fun env (id, (binding : Expr_translate.binding)) ->
           let binding_vars = Condition_closure.term_vars binding.term in
           if
             Expr_translate.find_var env id = None
             && Condition_closure.vars_subset binding_vars lhs_bound_vars
           then
             Expr_translate.add_var env id binding
           else
             env)
         env
  in
  if List.length terms = runtime_param_count params then
    Some terms, env_after, guards, diagnostics
  else
    None, env_after, guards, diagnostics

let translate_rhs ctx env origin exp =
  let exp_origin =
    child_origin origin "rhs" "Expr" exp.at (Some (Il.Print.string_of_exp exp))
  in
  Expr_translate.lower_value ctx env exp_origin exp

let translate_clause_premises ctx env origin lhs_terms lhs_guards prems =
  Premise_translate.translate_premises
    ctx
    env
    ~bound_conditions:lhs_guards
    ~bound_terms:lhs_terms
    origin
    prems

let rec premise_has_execution_dependency ctx prem =
  match prem.it with
  | RulePr (rel_id, _, _) ->
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | Some relation ->
      (match (Relation_shape.of_relation relation).Relation_shape.decision with
      | Relation_shape.Execution _ ->
        not (Analysis.Function_graph.relation_has_maude_equational_view relation)
      | Relation_shape.Static_validation _
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Unknown _ -> false)
    | None -> false)
  | IterPr (prem, _) | NegPr prem -> premise_has_execution_dependency ctx prem
  | IfPr _ | LetPr _ | ElsePr -> false

let rewrite_dependent_decd_diagnostic ctx origin id clause =
  unsupported
    ~ctx
    ~origin
    ~constructor:"DecD/rewrite-dependent"
    ~source_echo:(Il.Print.string_of_clause id clause)
    ~reason:
      "DecD clause premise depends on an execution rewrite relation; pure DecD lowering cannot emit rewrite conditions inside ceq"
    ~suggestion:
      "Keep this clause Unsupported until rewrite-dependent DecD helper/crl lowering is implemented"
    ()

let clause_seed id index =
  Naming.sanitize id.it ^ "-clause-" ^ string_of_int index

let translate_decd_clause ctx dec_origin op_name id params index clause =
  let origin =
    child_origin
      dec_origin
      (Printf.sprintf "DefD[%d]" index)
      "DefD"
      clause.at
      (Some (Il.Print.string_of_clause id clause))
  in
  let ctx = Context.with_clause ctx (Printf.sprintf "DefD[%d]" index) in
  match clause.it with
  | DefD (binds, args, rhs, prems) ->
    if List.exists (premise_has_execution_dependency ctx) prems then
      { statements = []
      ; diagnostics = [ rewrite_dependent_decd_diagnostic ctx origin id clause ]
      }
    else
    let env, var_decls, bind_diags =
      translate_clause_binds ctx origin (clause_seed id index) binds
    in
    let lhs_terms_opt, env, lhs_guards, lhs_diags =
      translate_clause_args ctx env origin params args
    in
    let premise_result =
      translate_clause_premises
        ctx
        env
        origin
        (Option.value ~default:[] lhs_terms_opt)
        lhs_guards
        prems
    in
    let rhs_result = translate_rhs ctx premise_result.env_after origin rhs in
    let diagnostics =
      bind_diags @ lhs_diags @ premise_result.diagnostics @ rhs_result.diagnostics
    in
    if has_fatal diagnostics then
      { statements = []; diagnostics }
    else
      match lhs_terms_opt, rhs_result.term with
      | Some lhs_terms, Some rhs_term ->
        let lhs = App (op_name, lhs_terms) in
        let attrs = if premise_result.has_else then [ Owise ] else [] in
        let conditions =
          lhs_guards @ premise_result.eq_conditions @ rhs_result.guards
          |> Condition_closure.normalize_binding_conditions lhs_terms
          |> dedup_conditions
        in
        let admissibility_diags =
          Condition_closure.ceq_admissibility_diagnostics ctx origin lhs rhs_term conditions
        in
        if has_fatal admissibility_diags then
          { statements = []; diagnostics = diagnostics @ admissibility_diags }
        else
          let statement =
            gen origin
              (ceq
                 ~attrs
                 lhs
                 rhs_term
                 conditions)
          in
          { statements = var_decls @ [ statement ]; diagnostics }
      | _ -> { statements = []; diagnostics }

let translate_decd_with_op ctx origin op_name id params result_typ clauses =
  let param_lowerings, param_diags =
    params
    |> List.map (decd_param_lowering ctx origin)
    |> List.split
  in
  let result_sort_opt, result_diags = decd_result_sort ctx origin result_typ in
  let diagnostics = List.concat param_diags @ result_diags in
  if has_fatal diagnostics then
    { empty with diagnostics }
  else
    match result_sort_opt with
    | None -> { empty with diagnostics }
    | Some result_sort ->
      let op_decl =
        gen origin
          (op op_name
             (param_lowerings
              |> List.filter_map (function
                | Runtime_param sort -> Some sort
                | Static_typ_param _ -> None
                | Static_def_param _ -> None
                | Unsupported_param -> None)
              |> List.map sort_ref)
             result_sort)
      in
      let clause_result =
        clauses
        |> List.mapi (fun index clause ->
          translate_decd_clause ctx origin op_name id param_lowerings (index + 1) clause)
        |> List.fold_left append empty
      in
      { statements = op_decl :: clause_result.statements
      ; diagnostics = diagnostics @ clause_result.diagnostics
      }

let skipped_static_template_without_instances ctx origin id =
  skipped
    ~ctx ~origin ~constructor:"DecD/static-template"
    ?source_echo:(source_echo origin)
    ~reason:
      ("static-param DecD `" ^ id.it
       ^ "` has no finite TypP/DefP specialization call site in this slice, so no generic Maude op is emitted")
    ~suggestion:"This template will be materialized when a concrete TypA or DefA call-site specialization is discovered"
    ()

let translate_decd ctx origin id params result_typ clauses =
  let has_static_param =
    params
    |> List.exists (fun param ->
      match param.it with
      | TypP _ | DefP _ -> true
      | ExpP _ | GramP _ -> false)
  in
  let has_unsupported_static_param =
    params
    |> List.exists (fun param ->
      match param.it with
      | GramP _ -> true
      | ExpP _ | TypP _ | DefP _ -> false)
  in
  if has_unsupported_static_param then
    let diagnostics =
      params
      |> List.filter_map (fun param ->
        match param.it with
        | GramP _ -> Some (unsupported_static_param ctx origin param)
        | ExpP _ | TypP _ | DefP _ -> None)
    in
    { empty with diagnostics }
  else if has_static_param then
    let specializations =
      Analysis.Function_graph.specializations_for (Context.function_graph ctx) id.it
    in
    (match specializations with
    | [] ->
      { empty with diagnostics = [ skipped_static_template_without_instances ctx origin id ] }
    | _ :: _ ->
      specializations
      |> List.map (fun specialization ->
        let ctx = Context.with_specialization ctx specialization in
        let op_name = Naming.specialized_definition_op id specialization.key_components in
        translate_decd_with_op ctx origin op_name id params result_typ clauses)
      |> List.fold_left append empty)
  else
    translate_decd_with_op ctx origin (Naming.definition_op id) id params result_typ clauses

let rec translate_def ctx path ordinal def =
  let origin = origin_for_def path ordinal def in
  match def.it with
  | TypD (id, params, insts) ->
    let ctx = Context.with_def ctx id.it in
    let translated = Type_translate.translate_typd ctx origin id params insts in
    { statements = translated.statements; diagnostics = translated.diagnostics }
  | DecD (id, params, result_typ, clauses) ->
    let ctx = Context.with_def ctx id.it in
    translate_decd ctx origin id params result_typ clauses
  | RelD (id, mixop, result_typ, rules) ->
    let ctx = Context.with_def ctx id.it in
    let translated = Reld_translate.translate ctx origin id mixop result_typ rules in
    { statements = translated.statements; diagnostics = translated.diagnostics }
  | GramD (id, _, _, _) ->
    let ctx = Context.with_def ctx id.it in
    let skip = Analysis.Profile_policy.gramd_skip in
    one_diagnostic
      (skipped
         ?suggestion:skip.suggestion
         ~ctx ~origin ~constructor:"GramD"
         ~reason:skip.reason
         ())
  | HintD hintdef ->
    translate_hintdef ctx origin hintdef
  | RecD defs ->
    List.mapi
      (fun index child ->
        translate_def ctx (origin.Origin.path @ [ Printf.sprintf "RecD[%d]" index ]) (index + 1) child)
      defs
    |> List.fold_left append empty

let rec preload_typd_registry_def ctx path ordinal def =
  let origin = origin_for_def path ordinal def in
  match def.it with
  | TypD (id, params, insts) ->
    let ctx = Context.with_def ctx id.it in
    Type_translate.preload_typd_registry ctx origin id params insts
  | RecD defs ->
    defs
    |> List.iteri (fun index child ->
      preload_typd_registry_def
        ctx
        (origin.Origin.path @ [ Printf.sprintf "RecD[%d]" index ])
        (index + 1)
        child)
  | DecD _ | RelD _ | GramD _ | HintD _ -> ()

let preload_typd_registry ctx script =
  script
  |> List.iteri (fun index def ->
    preload_typd_registry_def
      ctx
      [ Printf.sprintf "script[%d]" index ]
      (index + 1)
      def)

let translate_script ctx script =
  preload_typd_registry ctx script;
  List.mapi
    (fun index def -> translate_def ctx [ Printf.sprintf "script[%d]" index ] (index + 1) def)
    script
  |> List.fold_left append empty
