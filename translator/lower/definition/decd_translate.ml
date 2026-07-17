open Il.Ast
open Maude_ir
open Util.Source

type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let empty = { statements = []; diagnostics = [] }

let spectec_type = sort "SpectecType"

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
    ~enclosing:
      (Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) origin)
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

type decd_param_lowering =
  | Runtime_param of sort * typ
  | Phantom_typ_param of string
  | Static_def_param of Analysis.Function_graph.static_def_binding
  | Unsupported_param

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
    | Some sort -> Runtime_param (sort, typ), []
    | None -> Unsupported_param, [ unsupported_type ctx origin "DecD/param/ExpP" typ ])
  | TypP id -> Phantom_typ_param id.it, []
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

let translate_exp_bind ctx origin names env bind =
  match bind.it with
  | ExpP (id, typ) ->
    if id.it = "_" then
      env, [],
      [ unsupported
          ~ctx ~origin ~constructor:"DecD/DefD/ExpP"
          ~reason:"wildcard ExpP bind cannot be referenced safely in generated equation scope"
          ~suggestion:"Implement anonymous pattern bind handling before lowering this clause"
          ()
      ], names
    else
      (match Expr_translate.carrier_sort_of_typ typ with
      | Some sort ->
        let term =
          Local_name.source_qualified
            names id.it (Maude_ir.sort_ref sort)
        in
        let binding = { Expr_env.term; sort; typ } in
        let env = Expr_env.add env id.it binding in
        env, [], [], names
      | None ->
        env, [],
        [ unsupported_type ctx origin "DecD/DefD/ExpP" typ ], names)
  | TypP id ->
    if Context.find_static_typ ctx id.it <> None || Context.find_phantom_typ ctx id.it <> None then
      env, [],
      [ skipped
          ~ctx ~origin ~constructor:"DecD/DefD/bind/TypP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time syntax binder is represented by the current static context and has no runtime value variable"
          ~suggestion:
            "Keep the binder origin in diagnostics; do not emit it as a runtime argument"
          ()
      ], names
    else
      env, [],
      [ unsupported
          ~ctx ~origin ~constructor:"DecD/DefD/bind/TypP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time syntax binder is not bound by the current specialization, so erasing it would collapse source structure"
          ~suggestion:
            "Extend finite monomorphization to introduce this local static binder before lowering the clause"
          ()
      ], names
  | DefP (id, _, _) ->
    if Context.find_static_def ctx id.it <> None then
      env, [],
      [ skipped
          ~ctx ~origin ~constructor:"DecD/DefD/bind/DefP"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "compile-time definition binder is already fixed by the current DefP/DefA specialization and has no runtime Maude variable"
          ~suggestion:
            "Keep the binder origin in diagnostics; do not emit it as a runtime argument"
          ()
      ], names
    else
      env, [],
      [ unsupported
          ~ctx ~origin ~constructor:"DecD/DefD/static-bind"
          ~source_echo:(Il.Print.string_of_quant bind)
          ~reason:
            "local definition static clause bind is not bound by the current specialization"
          ~suggestion:"Specialize the enclosing DecD before lowering this clause"
          ()
      ], names
  | GramP _ ->
    env, [],
    [ unsupported
        ~ctx ~origin ~constructor:"DecD/DefD/static-bind"
        ~reason:"definition/grammar static clause binds require monomorphization and are outside pure DecD lowering"
        ~suggestion:"Specialize the enclosing DecD before lowering this clause"
        ()
    ], names

let translate_clause_binds ctx origin names binds =
  binds
  |> List.fold_left
       (fun (env, statements, diagnostics, names) bind ->
         let env, new_statements, new_diagnostics, names =
           translate_exp_bind ctx origin names env bind
         in
         env, statements @ new_statements, diagnostics @ new_diagnostics, names)
       (Expr_env.empty, [], [], names)

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
  ; arg_bindings : (string * Expr_env.binding) list
  ; arg_diagnostics : Diagnostics.t list
  }

let clause_arg_from_pattern (result : Expr_result.pattern_result) =
  { arg_term = result.pattern_term
  ; arg_guards = result.pattern_guards
  ; arg_bindings = result.introduced_bindings
  ; arg_diagnostics = result.pattern_diagnostics
  }

let rec typ_mentions_phantom ctx typ =
  match typ.it with
  | VarT (id, args) ->
    Context.find_phantom_typ ctx id.it <> None
    || List.exists (arg_mentions_phantom ctx) args
  | TupT fields -> List.exists (fun (_, typ) -> typ_mentions_phantom ctx typ) fields
  | IterT (typ, _) -> typ_mentions_phantom ctx typ
  | BoolT | NumT _ | TextT -> false

and arg_mentions_phantom ctx arg =
  match arg.it with
  | TypA typ -> typ_mentions_phantom ctx typ
  | ExpA _ | DefA _ | GramA _ -> false

let add_phantom_runtime_guards ctx env origin typ sort arg =
  if not (typ_mentions_phantom ctx typ) then
    arg
  else
    match arg.arg_term with
    | None -> arg
    | Some term ->
      let witness =
        Expr_translate.lower_type_witness
          ctx
          env
          origin
          ~constructor:"DecD/DefD/runtime-arg/type-witness"
          typ
      in
      let witness_guards =
        match witness.term with
        | Some typ_term ->
          witness.guards
          @ Expr_translate.typecheck_conditions_for_typ typ sort term typ_term
        | None -> witness.guards
      in
      { arg with
        arg_guards = arg.arg_guards @ witness_guards
      ; arg_diagnostics = arg.arg_diagnostics @ witness.diagnostics
      }

let clause_arg_none diagnostics =
  { arg_term = None; arg_guards = []; arg_bindings = []; arg_diagnostics = diagnostics }

let translate_clause_arg names ctx env origin param arg =
  match param, arg.it with
  | Runtime_param (sort, typ), ExpA exp ->
    let exp_origin =
      child_origin origin "lhs-arg" "Expr" exp.at (Some (Il.Print.string_of_exp exp))
    in
    let result, names =
      Expr_translate.lower_pattern_with_bindings_named
        names ctx env exp_origin exp
    in
    ( result
      |> clause_arg_from_pattern
      |> add_phantom_runtime_guards ctx env exp_origin typ sort
    , names )
  | Runtime_param _, (TypA _ | DefA _ | GramA _) ->
    ( clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/runtime-arg"
            arg
            "runtime DecD parameter position received a static clause argument"
        ]
    , names )
  | Phantom_typ_param _, TypA typ ->
    let result =
      Expr_translate.lower_type_witness
        ctx
        env
        origin
        ~constructor:"DecD/DefD/static-arg/TypA"
        typ
    in
    ( { arg_term = result.term
    ; arg_guards = result.guards
    ; arg_bindings = []
    ; arg_diagnostics = result.diagnostics
      }
    , names )
  | Phantom_typ_param _, (ExpA _ | DefA _ | GramA _) ->
    ( clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/TypP"
            arg
            "TypP parameter position requires a TypA clause argument"
        ]
    , names )
  | Static_def_param expected, DefA actual_id ->
    let resolved_actual_id =
      match Context.find_static_def ctx actual_id.it with
      | Some target_id -> target_id
      | None -> actual_id.it
    in
    if resolved_actual_id = expected.target_id then
      clause_arg_none [], names
    else
      ( clause_arg_none
          [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/DefA"
              arg
              ("static definition clause argument does not match current specialization target `"
               ^ expected.target_id ^ "`")
          ]
      , names )
  | Static_def_param _, (ExpA _ | TypA _ | GramA _) ->
    ( clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg/DefP"
            arg
            "DefP parameter position requires a DefA clause argument in this specialization slice"
        ]
    , names )
  | Unsupported_param, _ ->
    ( clause_arg_none
        [ unsupported_clause_arg ctx origin "DecD/DefD/static-arg"
            arg
            "clause argument belongs to an unsupported static parameter kind"
        ]
    , names )

let runtime_param_count params =
  params
  |> List.fold_left
       (fun count -> function
         | Runtime_param _ -> count + 1
         | Phantom_typ_param _ -> count + 1
         | Static_def_param _ -> count
         | Unsupported_param -> count)
       0

let arg_terms results =
  List.filter_map (fun result -> result.arg_term) results

let arg_guards results =
  results |> List.map (fun result -> result.arg_guards) |> List.concat

let arg_bindings results =
  results |> List.map (fun result -> result.arg_bindings) |> List.concat

let arg_diagnostics results =
  results |> List.map (fun result -> result.arg_diagnostics) |> List.concat

let add_safe_arg_bindings env results =
  let terms = arg_terms results in
  let guards = arg_guards results in
  let lhs_bound_vars =
    Condition_closure.conditions_bound_vars
      (terms
       |> List.map Condition_closure.term_vars
       |> List.concat
       |> List.sort_uniq String.compare)
      guards
  in
  arg_bindings results
  |> List.fold_left
       (fun env (id, (binding : Expr_env.binding)) ->
         let binding_vars = Condition_closure.term_vars binding.term in
         if
           Condition_closure.vars_subset binding_vars lhs_bound_vars
         then
           Expr_env.add env id binding
         else
           env)
       env

let translate_clause_args_named names ctx env origin params args =
  let source_names =
    args
    |> List.concat_map (fun arg ->
      match arg.it with
      | ExpA exp ->
        Il.Free.(free_exp exp).varid |> Il.Free.Set.elements
      | TypA _ | DefA _ | GramA _ -> [])
    |> List.sort_uniq String.compare
  in
  let names = Local_name.reserve_sources names source_names in
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
    ],
    names
  else
  let rec lower_args names env results_rev params args =
    match params, args with
    | [], [] -> env, List.rev results_rev, names
    | param :: params, arg :: args ->
      let result, names =
        translate_clause_arg names ctx env origin param arg
      in
      let results = List.rev (result :: results_rev) in
      let env = add_safe_arg_bindings env results in
      lower_args names env (result :: results_rev) params args
    | [], _ :: _ | _ :: _, [] -> env, List.rev results_rev, names
  in
  let env_after, results, names = lower_args names env [] params args in
  let terms = arg_terms results in
  let guards = arg_guards results in
  let diagnostics = arg_diagnostics results in
  if List.length terms = runtime_param_count params then
    Some terms, env_after, guards, diagnostics, names
  else
    None, env_after, guards, diagnostics, names

let translate_rhs ctx env origin exp =
  let exp_origin =
    child_origin origin "rhs" "Expr" exp.at (Some (Il.Print.string_of_exp exp))
  in
  Expr_translate.lower_value ctx env exp_origin exp

let translate_clause_premises_named
    names ctx env origin lhs_terms lhs_guards ~condition_declarations
    ~escape_source_ids prems =
  Premise_translate.translate_premises_named
    names
    ~condition_declarations
    ctx
    env
    ~bound_conditions:lhs_guards
    ~escape_source_ids
    ~bound_terms:lhs_terms
    origin
    prems

let rec premise_has_execution_dependency ctx prem =
  match prem.it with
  | RulePr (rel_id, _, _, _) ->
    (match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
    | Some relation ->
      (match (Relation_shape.of_relation relation).Relation_shape.decision with
      | Relation_shape.Execution _ -> true
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

let pure_rule_condition_diagnostic ctx origin id clause count =
  unsupported
    ~ctx
    ~origin
    ~constructor:"DecD/pure/rule-condition"
    ~source_echo:(Il.Print.string_of_clause id clause)
    ~reason:
      (Printf.sprintf
         "ordinary DecD premise lowering produced %d rewrite condition(s); eq/ceq cannot contain RewriteCond, and discarding them would erase a source-derived witness obligation"
         count)
    ~suggestion:
      "Promote this definition from an AST-derived rewrite dependency, or keep the clause Unsupported until the rewrite-only obligation has a sound rl/crl lowering"
    ()

let with_phantom_params names ctx params =
  params
  |> List.fold_left
       (fun (ctx, names) -> function
         | Phantom_typ_param id ->
           let names = Local_name.reserve_phantom names id in
           let variable =
             Local_name.phantom_qualified_name
               names id (sort_ref (sort "SpectecType"))
           in
           Context.with_phantom_typ ctx id variable, names
         | Runtime_param _ | Static_def_param _ | Unsupported_param ->
           ctx, names)
       (ctx, names)

let rec with_runtime_premise_use dec_id ctx prem =
  match prem.it with
  | RulePr (rel_id, _, _, _) ->
    (match
       Analysis.Function_graph.find_relation
         (Context.function_graph ctx) rel_id.it
     with
    | Some relation
      when relation.kind = Analysis.Relation_graph.Predicate_candidate ->
      Context.with_runtime_relation_use ctx rel_id.it
        ("predicate relation `" ^ rel_id.it
         ^ "` occurs in emitted DecD `" ^ dec_id.it
         ^ "`; this exact RulePr use constrains runtime semantics and has no use-local external-validation certificate")
    | Some _ | None -> ctx)
  | IterPr (body, _) | NegPr body ->
    with_runtime_premise_use dec_id ctx body
  | IfPr _ | LetPr _ | ElsePr -> ctx

let with_runtime_premise_uses dec_id ctx prems =
  List.fold_left (with_runtime_premise_use dec_id) ctx prems

let decd_has_runtime_semantics ctx id =
  let graph = Context.function_graph ctx in
  let identity =
    match Context.current_specialization ctx with
    | Some specialization when String.equal specialization.def_id id.it ->
      Analysis.Function_graph.identity_of_specialization specialization
    | Some _ | None -> Analysis.Function_graph.plain_identity id.it
  in
  Analysis.Function_graph.identity_is_rewrite_backed graph identity
  || Analysis.Function_graph.definition_is_runtime_entry graph id.it

let discharge_runtime_ingress_slices ctx id clause_index args rhs prems =
  let discharge =
    Runtime_ingress_slice_certificate.certify
      ctx ~definition_id:id.it ~clause_index ~lhs_args:args ~rhs prems
  in
  let diagnostics =
    (discharge.certificates
     |> List.map (fun certificate ->
      let first = Runtime_ingress_slice_certificate.first_index certificate in
      let last = Runtime_ingress_slice_certificate.last_index certificate in
      skipped
        ~ctx
        ~origin:(Runtime_ingress_slice_certificate.origin certificate)
        ~constructor:"DecD/runtime-ingress-validation-slice"
        ~source_echo:(Runtime_ingress_slice_certificate.source_echo certificate)
        ~reason:
          (Printf.sprintf
             "source-contiguous premises %d..%d form a certified runtime-ingress validation slice from contract %s; validation-local witness(es) `%s` are consumed only inside the slice and do not escape to the DefD rhs or remaining premises"
             first last
             (Option.value ~default:"<unknown>"
                (Runtime_ingress_slice_certificate.contract_origin certificate))
             (String.concat "`, `"
                (Runtime_ingress_slice_certificate.introduced_source_ids certificate)))
        ~suggestion:
          "Retain this typed ingress certificate with the runtime-entry profile; if the slice shape or non-escape proof changes, lower it explicitly or report Unsupported"
        ()))
    @ (discharge.blockers
       |> List.map (fun blocker ->
         unsupported
           ~ctx
           ~origin:(Runtime_ingress_slice_certificate.blocker_origin blocker)
           ~constructor:"DecD/runtime-ingress-validation-slice/blocked"
           ~source_echo:
             (Runtime_ingress_slice_certificate.blocker_source_echo blocker)
           ~reason:(Runtime_ingress_slice_certificate.blocker_reason blocker)
           ~suggestion:
             (Runtime_ingress_slice_certificate.blocker_suggestion blocker)
           ()))
  in
  discharge.retained, diagnostics

let local_names_for_clause clause =
  let free = Il.Free.(free_clause clause).varid |> Il.Free.Set.elements in
  let bound =
    match clause.it with
    | DefD (quants, _, _, prems) ->
      let quants =
        Il.Free.(bound_quants quants).varid |> Il.Free.Set.elements
      in
      let prems =
        prems
        |> List.concat_map (fun prem ->
          Il.Free.(bound_prem prem).varid |> Il.Free.Set.elements)
      in
      quants @ prems
  in
  Local_name.reserve_sources
    Local_name.empty (List.sort_uniq String.compare (free @ bound))

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
    let names = local_names_for_clause clause in
    let ctx, names = with_phantom_params names ctx params in
    let prems, ingress_diagnostics =
      discharge_runtime_ingress_slices ctx id (index - 1) args rhs prems
    in
    let ctx =
      if decd_has_runtime_semantics ctx id then
        with_runtime_premise_uses id ctx prems
      else
        ctx
    in
    if has_fatal ingress_diagnostics then
      { statements = []; diagnostics = ingress_diagnostics }
    else if List.exists (premise_has_execution_dependency ctx) prems then
      { statements = []
      ; diagnostics = [ rewrite_dependent_decd_diagnostic ctx origin id clause ]
      }
    else
    let env, var_decls, bind_diags, names =
      translate_clause_binds ctx origin names binds
    in
    let lhs_terms_opt, env, lhs_guards, lhs_diags, names =
      translate_clause_args_named names ctx env origin params args
    in
    let premise_translation, _names =
      translate_clause_premises_named
        names
        ctx
        env
        origin
        (Option.value ~default:[] lhs_terms_opt)
        lhs_guards
        ~condition_declarations:var_decls
        ~escape_source_ids:(Source_free_vars.exp_and_note_ids rhs)
        prems
    in
    (match premise_translation with
    | Premise_result.Blocked diagnostics
    | Deferred (_, diagnostics) ->
      { statements = []
      ; diagnostics =
          bind_diags @ lhs_diags @ ingress_diagnostics @ diagnostics
      }
    | Complete premise_result ->
    let rule_conditions = Premise_result.rule_conditions premise_result in
    if rule_conditions <> [] then
      { statements = []
      ; diagnostics =
          bind_diags @ lhs_diags @ ingress_diagnostics
          @ Premise_result.diagnostics premise_result
          @ [ pure_rule_condition_diagnostic
                ctx origin id clause (List.length rule_conditions) ]
      }
    else
    let rhs_result =
      translate_rhs ctx (Premise_result.env_after premise_result) origin rhs
    in
    let diagnostics =
      bind_diags @ lhs_diags @ ingress_diagnostics
      @ Premise_result.diagnostics premise_result @ rhs_result.diagnostics
    in
    if has_fatal diagnostics then
      { statements = []; diagnostics }
    else
      match lhs_terms_opt, rhs_result.term with
      | Some lhs_terms, Some rhs_term ->
        let lhs = App (op_name, lhs_terms) in
        let attrs = if Premise_result.has_else premise_result then [ Owise ] else [] in
        let pattern_certificate =
          Premise_result.condition_pattern_certificate
            ~declarations:var_decls ctx premise_result
        in
        let conditions =
          lhs_guards @ Premise_result.eq_conditions premise_result
          @ rhs_result.guards
          |> Condition_closure.normalize_binding_conditions
               ~constructor_op:pattern_certificate
               lhs_terms
          |> dedup_conditions
        in
        let admissibility_diags =
          Condition_admissibility.ceq_admissibility_diagnostics
            ~constructor_op:pattern_certificate
            ctx origin lhs rhs_term conditions
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
      | _ -> { statements = []; diagnostics })

let rewrite_conf_sort ctx id =
  let targets =
    match Context.current_specialization ctx with
    | Some specialization when specialization.def_id = id.it ->
      specialization.static_defs
      |> List.map (fun binding -> binding.Analysis.Function_graph.target_id)
    | Some _ | None -> []
  in
  sort (Naming.definition_config_sort id targets)

let rewrite_clause_label id index =
  Maude_ir.sanitize_label (id.it ^ "-clause-" ^ string_of_int index)

let translate_rewrite_decd_clause ctx dec_origin op_name id params index clause =
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
    let names = local_names_for_clause clause in
    let ctx, names = with_phantom_params names ctx params in
    let prems, ingress_diagnostics =
      discharge_runtime_ingress_slices ctx id (index - 1) args rhs prems
    in
    let ctx =
      if decd_has_runtime_semantics ctx id then
        with_runtime_premise_uses id ctx prems
      else
        ctx
    in
    if has_fatal ingress_diagnostics then
      { statements = []; diagnostics = ingress_diagnostics }
    else
    let env, var_decls, bind_diags, names =
      translate_clause_binds ctx origin names binds
    in
    let lhs_terms_opt, env, lhs_guards, lhs_diags, names =
      translate_clause_args_named names ctx env origin params args
    in
    let lhs_terms = Option.value ~default:[] lhs_terms_opt in
    let premise_translation, names =
      Reld_execution_premise.translate_premises_named
        names
        ~require_equational_contract:true
        ctx
        env
        ~bound_conditions:lhs_guards
        ~escape_source_ids:(Source_free_vars.exp_and_note_ids rhs)
        ~bound_terms:lhs_terms
        origin
        prems
    in
    (match premise_translation with
    | Premise_result.Blocked diagnostics
    | Deferred (_, diagnostics) ->
      { statements = []
      ; diagnostics =
          bind_diags @ lhs_diags @ ingress_diagnostics @ diagnostics
      }
    | Complete premise_result ->
    let rhs_result =
      translate_rhs ctx (Premise_result.env_after premise_result) origin rhs
    in
    let lhs_conditions, lhs_condition_diags, names =
      Decd_rewrite_condition.lower_eq_conditions ctx origin names lhs_guards
    in
    let premise_eq_conditions, premise_eq_diags, names =
      Decd_rewrite_condition.lower_eq_conditions
        ctx origin names (Premise_result.eq_conditions premise_result)
    in
    let premise_rule_conditions, premise_rule_diags, names =
      Decd_rewrite_condition.lower_rule_conditions
        ctx origin names (Premise_result.rule_conditions premise_result)
    in
    let rhs_term_result, names =
      match rhs_result.term with
      | None -> None, names
      | Some term ->
        let result, names =
          Decd_rewrite_condition.lower_term ctx origin names term
        in
        Some result, names
    in
    let rhs_guard_conditions, rhs_guard_diags, _names =
      Decd_rewrite_condition.lower_eq_conditions
        ctx origin names rhs_result.guards
    in
    let rewrite_diags =
      lhs_condition_diags @ premise_eq_diags @ premise_rule_diags
      @ Option.fold ~none:[] ~some:(fun result -> result.Decd_rewrite_condition.diagnostics)
          rhs_term_result
      @ rhs_guard_diags
    in
    let else_diags =
      if Premise_result.has_else premise_result then
        [ unsupported
            ~ctx ~origin ~constructor:"DecD/rewrite-backed/ElsePr"
            ~source_echo:(Il.Print.string_of_clause id clause)
            ~reason:
              "promoted DecD ElsePr needs a source-derived predecessor enabledness complement; rewrite rules cannot use equation [owise]"
            ~suggestion:
              "Preprocess the source fallback into an explicit admissible complement before lowering this clause"
            ()
        ]
      else
        []
    in
    let diagnostics =
      bind_diags @ lhs_diags @ ingress_diagnostics
      @ Premise_result.diagnostics premise_result @ rhs_result.diagnostics
      @ rewrite_diags @ else_diags
    in
    if has_fatal diagnostics then
      { statements = []; diagnostics }
    else
      match lhs_terms_opt, rhs_term_result with
      | Some lhs_terms, Some rhs_result ->
        let lhs = App (op_name, lhs_terms) in
        let pattern_certificate =
          Premise_result.condition_pattern_certificate
            ~declarations:var_decls ctx premise_result
        in
        let conditions =
          lhs_conditions @ premise_eq_conditions @ premise_rule_conditions
          @ rhs_result.conditions @ rhs_guard_conditions
          |> Condition_closure.normalize_rule_conditions
               ~constructor_op:pattern_certificate
               [ lhs ]
          |> Reld_result.dedup_rule_conditions
        in
        let admissibility_diags =
          Condition_admissibility.crl_admissibility_diagnostics
            ~constructor_op:pattern_certificate
            ctx origin lhs rhs_result.term conditions
        in
        if has_fatal admissibility_diags then
          { statements = []; diagnostics = diagnostics @ admissibility_diags }
        else
          let statement =
            gen origin
              (crl
                 ~label:(rewrite_clause_label id index)
                 lhs rhs_result.term conditions)
          in
          let registry_diags =
            Reld_rule_lowering.generated_statement_diagnostics
              ~pattern_certificate
              ctx statement
          in
          if has_fatal registry_diags then
            { statements = []; diagnostics = diagnostics @ registry_diags }
          else
            { statements = var_decls @ [ statement ]; diagnostics }
      | _ -> { statements = []; diagnostics })

let translate_rewrite_decd_with_op
    ctx origin op_name id param_lowerings result_sort clauses diagnostics =
  let runtime_sorts =
    param_lowerings
    |> List.filter_map (function
      | Runtime_param (sort, _) -> Some sort
      | Phantom_typ_param _ -> Some spectec_type
      | Static_def_param _ | Unsupported_param -> None)
  in
  let conf_sort = rewrite_conf_sort ctx id in
  let header =
    [ gen origin (sort_decl conf_sort)
    ; gen origin (subsort result_sort conf_sort)
    ; gen origin
        (op
           ~attrs:(Reld_rule_lowering.frozen_all (List.length runtime_sorts))
           op_name (List.map sort_ref runtime_sorts) conf_sort)
    ]
  in
  let clauses =
    clauses
    |> List.mapi (fun index clause ->
      translate_rewrite_decd_clause
        ctx origin op_name id param_lowerings (index + 1) clause)
    |> List.fold_left append empty
  in
  { statements = header @ clauses.statements
  ; diagnostics = diagnostics @ clauses.diagnostics
  }

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
      let identity =
        match Context.current_specialization ctx with
        | Some specialization when specialization.def_id = id.it ->
          Analysis.Function_graph.identity_of_specialization specialization
        | Some _ | None -> Analysis.Function_graph.plain_identity id.it
      in
      if Analysis.Function_graph.identity_is_rewrite_backed
           (Context.function_graph ctx) identity
      then
        translate_rewrite_decd_with_op
          ctx origin op_name id param_lowerings result_sort clauses diagnostics
      else
      let op_decl =
        let kind =
          if
            Analysis.Function_graph.definition_is_partial
              (Context.function_graph ctx) id.it
            || Builtin_registry.declaration_is_partial
                 (Context.builtins ctx) id.it
          then Partial else Total
        in
        gen origin
          (op ~kind op_name
             (param_lowerings
              |> List.filter_map (function
                | Runtime_param (sort, _) -> Some sort
                | Phantom_typ_param _ -> Some spectec_type
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

let translate ctx origin id params result_typ clauses =
  let has_static_def_param =
    params
    |> List.exists (fun param ->
      match param.it with
      | DefP _ -> true
      | ExpP _ | TypP _ | GramP _ -> false)
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
  else if has_static_def_param then
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
        let op_name = Context.specialized_definition_op ctx id specialization in
        translate_decd_with_op ctx origin op_name id params result_typ clauses)
      |> List.fold_left append empty)
  else
    translate_decd_with_op ctx origin (Context.definition_op ctx id) id params result_typ clauses
