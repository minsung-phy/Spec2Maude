open Il.Ast
open Maude_ir
open Util.Source

include Type_support

open Type_numeric

open Type_inherited

let hint_diagnostics ctx origin owner hints =
  hints
  |> List.map (fun hint ->
    let constructor = owner ^ "/hint(" ^ hint.hintid.it ^ ")" in
    match Analysis.Hint_policy.classify hint with
    | Presentation ->
      false,
      skipped
        ~ctx ~origin ~constructor
        ~source_echo:hint.hintid.it
        ~reason:"presentation hint has no runtime rewrite meaning in this profile"
        ~suggestion:"The hint is recorded as metadata rather than emitted as Maude"
        ()
    | Semantic_obligation ->
      false,
      obligation
        ~ctx ~origin ~constructor
        ~source_echo:hint.hintid.it
        ~reason:"semantic hint creates an external prelude/builtin obligation"
        ~suggestion:"Provide the hinted behavior in a verified prelude or builtin module before generated code depends on it"
        ()
    | Translator_annotation ->
      false,
      skipped
        ~ctx ~origin ~constructor
        ~source_echo:hint.hintid.it
        ~reason:"translator annotation is consumed by analysis and has no direct runtime Maude statement"
        ~suggestion:"Keep the hint in provenance rather than emitting Maude code for it"
        ()
    | Unknown ->
      true,
      unsupported
        ~ctx ~origin ~constructor
        ~source_echo:hint.hintid.it
        ~reason:"unknown hint cannot be erased silently"
        ~suggestion:"Classify this hint as presentation metadata, semantic obligation, or an unsupported semantic construct"
        ())

let unsupported_binds ctx origin owner binds =
  binds
  |> List.map (fun bind ->
    unsupported
      ~ctx ~origin ~constructor:(owner ^ "/binds")
      ~source_echo:(Il.Print.string_of_quant bind)
      ~reason:
        "typcase/typfield/InstD bind lists require local scope extension; this fix slice treats every nonempty quant list as unsupported rather than silently accepting ExpP"
      ~suggestion:"Implement bind scope extension before emitting guarded constructor, record, or family-instance fragments"
      ())

let component_matches_exp_bind bind_id bind_typ (payload, typ) =
  ignore bind_typ;
  ignore typ;
  match payload_source_id payload with
  | Some payload_id -> payload_id = bind_id.it
  | None -> false

let constructor_bind_diagnostics ctx origin owner binds components prems =
  let bind_source bind =
    match prems with
    | [] -> Il.Print.string_of_quant bind
    | _ ->
      Il.Print.string_of_quant bind ^ " -- "
      ^ String.concat "; " (List.map Il.Print.string_of_prem prems)
  in
  binds
  |> List.filter_map (fun bind ->
    match bind.it with
    | ExpP (id, typ) when List.exists (component_matches_exp_bind id typ) components ->
      None
    | ExpP (id, _) when hidden_exp_bind_supported id components prems ->
      None
    | ExpP _ when prems = [] ->
      Some
        (skipped
           ~ctx ~origin ~constructor:(owner ^ "/binds")
           ~source_echo:(bind_source bind)
           ~reason:
             "constructor ExpP binder is not referenced by premises; payload shape is preserved by the constructor arguments and the binder is recorded as metadata"
           ~suggestion:
             "Keep this non-fatal only while the binder is unused by typcase premises"
           ())
    | _ ->
      Some
        (unsupported
           ~ctx ~origin ~constructor:(owner ^ "/binds")
           ~source_echo:(bind_source bind)
           ~reason:
             "typcase bind lowering only supports payload ExpP binders, or unused ExpP binders on premise-free constructor cases"
           ~suggestion:
             "Implement full typcase scope extension before emitting guarded constructor fragments with independent binders"
           ()))

let unsupported_inst_bind ctx origin bind =
  unsupported
    ~ctx ~origin ~constructor:"TypD/InstD/binds"
    ~source_echo:(Il.Print.string_of_quant bind)
    ~reason:
      "InstD bind lowering only supports type-level TypP binders in this parse-safety slice; value, definition, and grammar binders require their own scope semantics"
    ~suggestion:"Implement the corresponding InstD binder scope extension before emitting this family instance"
    ()

let unsupported_inst_numeric_bind ctx origin bind =
  unsupported
    ~ctx ~origin ~constructor:"TypD/InstD/binds/ExpP"
    ~source_echo:(Il.Print.string_of_quant bind)
    ~reason:
      "InstD expression binders are lowered here only when their carrier resolves structurally to primitive Nat or Int; this binder would otherwise make arithmetic over SpectecTerminal"
    ~suggestion:
      "Add a verified static numeric alias/specialization rule before lowering this family instance"
    ()

let translate_inst_binds ctx origin seed env binds =
  binds
  |> List.mapi (fun index bind -> index + 1, bind)
  |> List.fold_left
       (fun (env, statements, diagnostics) (index, bind) ->
         match bind.it with
         | TypP id ->
           (match lookup id.it env.typ_vars with
           | Some _ -> env, statements, diagnostics
           | None ->
             let name = Naming.maude_var (seed ^ "_T_BIND_" ^ id.it ^ "_" ^ string_of_int index) in
             let term = Var name in
             { env with typ_vars = (id.it, term) :: env.typ_vars },
             statements @ [ gen origin (var name (sr spectec_type)) ],
             diagnostics)
         | ExpP (id, typ) ->
           (match lookup id.it env.exp_vars with
           | Some _ -> env, statements, diagnostics
           | None ->
             let sort_opt, sort_diags =
               carrier_sort_of_typ ctx origin "TypD/InstD/binds/ExpP" typ
             in
             (match sort_opt with
             | Some sort ->
               let name =
                 Naming.maude_var (seed ^ "_E_BIND_" ^ id.it ^ "_" ^ string_of_int index)
               in
               let term = Var name in
               let binding = { static_term = term; static_sort = sort; static_typ = typ } in
               { env with exp_vars = (id.it, binding) :: env.exp_vars },
               statements @ [ gen origin (var name (sr sort)) ],
               diagnostics @ sort_diags
             | None ->
               env,
               statements,
               diagnostics @ sort_diags @ [ unsupported_inst_numeric_bind ctx origin bind ]))
         | DefP _ | GramP _ ->
           env, statements, diagnostics @ [ unsupported_inst_bind ctx origin bind ])
       (env, [], [])

let unsupported_prems ctx origin owner prems =
  prems
  |> List.map (fun prem ->
    unsupported
      ~ctx ~origin ~constructor:(owner ^ "/premise")
      ?source_echo:(source_echo_prem prem)
      ~reason:
        "typcase/typfield premises cannot yet be lowered into sound constructor or record membership conditions"
      ~suggestion:"Route this premise through the premise translator before emitting the guarded Maude fragment"
      ())

let payload_diagnostics ctx origin constructor payload =
  match payload_source_id payload with
  | Some _ -> []
  | None ->
  match payload.it with
  | VarE _ -> []
  | _ ->
    [ unsupported
        ~ctx ~origin ~constructor:(constructor ^ "/tuple-payload")
        ~source_echo:(Il.Print.string_of_exp payload)
        ~reason:
          "non-variable tuple payload may carry source shape metadata and is not discarded in Milestone A"
        ~suggestion:"Preserve this payload through the tuple/config shape encoding before lowering the component"
        ()
    ]

let lower_component env ctx origin constructor seed index (payload, typ) =
  let payload_diagnostics =
    payload_diagnostics ctx origin constructor payload
  in
  let sort_opt, sort_diagnostics = carrier_sort_of_typ ctx origin constructor typ in
  let witness_opt, witness_diagnostics = witness_of_typ env ctx origin constructor typ in
  match payload_diagnostics, sort_opt, witness_opt with
  | _ :: _, _, _ -> None
  | [], Some sort, Some witness ->
    let source_id = payload_source_id payload in
    Some
      { variable = var_name_from_exp seed "A" index payload sort
      ; sort
      ; typ
      ; source_id
      ; witness
      ; diagnostics = payload_diagnostics @ sort_diagnostics @ witness_diagnostics
      }
  | [], _, _ -> None

let component_diagnostics env ctx origin constructor (payload, typ) =
  let payload_diags = payload_diagnostics ctx origin constructor payload in
  let _, sort_diags = carrier_sort_of_typ ctx origin constructor typ in
  let _, witness_diags = witness_of_typ env ctx origin constructor typ in
  payload_diags @ sort_diags @ witness_diags

let env_with_component env component =
  match component.source_id with
  | None -> env
  | Some id ->
    let binding =
      { static_term = Var component.variable
      ; static_sort = component.sort
      ; static_typ = component.typ
      }
    in
    { env with exp_vars = (id, binding) :: env.exp_vars }

let lower_components env ctx origin constructor seed components =
  let _env, lowered_rev, diagnostics, failed =
    components
     |> List.mapi (fun index component -> index + 1, component)
     |> List.fold_left
         (fun (env, lowered_rev, diagnostics, failed) (index, component) ->
           match lower_component env ctx origin constructor seed index component with
           | Some lowered ->
             env_with_component env lowered,
             lowered :: lowered_rev,
             diagnostics @ lowered.diagnostics,
             failed
           | None ->
             env,
             lowered_rev,
             diagnostics @ component_diagnostics env ctx origin constructor component,
             true)
         (env, [], [], false)
  in
  if failed then None, diagnostics else Some (List.rev lowered_rev), diagnostics

let exp_param_sort ctx origin typ =
  let sort_opt, diagnostics = carrier_sort_of_typ ctx origin "TypD/param/ExpP" typ in
  Option.value sort_opt ~default:spectec_terminal, diagnostics

let param_type_ref ctx origin param =
  match param.it with
  | ExpP (_, typ) ->
    let sort, diagnostics = exp_param_sort ctx origin typ in
    Some (sr sort), diagnostics
  | TypP _ -> Some (sr spectec_type), []
  | DefP _ | GramP _ -> None, []

let static_param_diagnostic ctx origin param =
  unsupported
    ~ctx ~origin ~constructor:"TypD/param/static"
    ~source_echo:(Il.Print.string_of_param param)
    ~reason:
      "DefP/GramP are compile-time static parameters and need a sound witness encoding before TypD lowering"
    ~suggestion:"Implement finite static specialization or a type-level witness encoding before lowering this TypD"
    ()

let param_binding_invariant param reason =
  invalid_arg
    (Printf.sprintf
       "Type_translate.param_binding invariant failed for parameter %S: %s"
       (Il.Print.string_of_param param) reason)

let param_binding ctx origin _seed index param =
  let name =
    match param.it with
    | ExpP (id, _) ->
      Naming.maude_var (id.it ^ "_P" ^ string_of_int index)
    | TypP id ->
      Naming.maude_var (id.it ^ "_T" ^ string_of_int index)
    | DefP _ | GramP _ ->
      param_binding_invariant param
        "static DefP/GramP must be rejected before runtime parameter binding"
  in
  let type_ref, diagnostics =
    match param_type_ref ctx origin param with
    | Some type_ref, diagnostics -> type_ref, diagnostics
    | None, _ ->
      param_binding_invariant param
        "parameter has no Maude runtime type reference"
  in
  let term = Var name in
  let env_update env =
    match param.it with
    | ExpP (id, typ) ->
      let sort, _diagnostics = exp_param_sort ctx origin typ in
      let binding = { static_term = term; static_sort = sort; static_typ = typ } in
      { env with exp_vars = (id.it, binding) :: env.exp_vars }
    | TypP id -> { env with typ_vars = (id.it, term) :: env.typ_vars }
    | DefP _ | GramP _ ->
      param_binding_invariant param
        "static DefP/GramP cannot update runtime expression/type environments"
  in
  gen origin (var name type_ref), env_update, term, diagnostics

let target_witness witness_name args =
  app witness_name args

let translate_alias env ctx origin seed key_env static_args_key target typ =
  Type_alias.translate_alias env ctx origin seed key_env static_args_key target typ

let translate_category_union env ctx origin seed key_env static_args_key target child_typ =
  Type_alias.translate_category_union env ctx origin seed key_env static_args_key target child_typ

let expr_env_with_components env components =
  components
  |> List.fold_left
       (fun expr_env component ->
         match component.source_id with
         | None -> expr_env
         | Some id ->
           Expr_translate.add_var
             expr_env
             id
             { Expr_translate.term = Var component.variable
             ; sort = component.sort
             ; typ = component.typ
             })
       (expr_env_of_static_env env)

let expr_env_with_hidden_binds expr_env hidden_binds =
  hidden_binds
  |> List.fold_left
       (fun expr_env hidden ->
         Expr_translate.add_var
           expr_env
           hidden.hidden_source_id
           { Expr_translate.term = Var hidden.hidden_variable
           ; sort = hidden.hidden_sort
           ; typ = hidden.hidden_typ
           })
       expr_env

let hidden_bind_var_name seed index id sort =
  Naming.maude_var
    (seed ^ "_" ^ id ^ "_hidden_" ^ variable_sort_suffix sort ^ "_" ^ string_of_int index)

let lower_hidden_exp_binds env ctx origin seed components prems binds =
  binds
  |> List.mapi (fun index bind -> index + 1, bind)
  |> List.filter_map (fun (index, bind) ->
    match bind.it with
    | ExpP (id, typ)
      when hidden_exp_bind_supported id components prems ->
      let sort_opt, sort_diags =
        carrier_sort_of_typ ctx origin "VariantT/constructor/hidden-bind" typ
      in
      let witness_opt, witness_diags =
        witness_of_typ env ctx origin "VariantT/constructor/hidden-bind" typ
      in
      let diagnostics = sort_diags @ witness_diags in
      (match sort_opt, witness_opt with
      | Some sort, Some witness ->
        Some
          { hidden_source_id = id.it
          ; hidden_variable = hidden_bind_var_name seed index id.it sort
          ; hidden_sort = sort
          ; hidden_typ = typ
          ; hidden_witness = witness
          ; hidden_diagnostics = diagnostics
          }
      | _ ->
        Some
          { hidden_source_id = id.it
          ; hidden_variable = hidden_bind_var_name seed index id.it spectec_terminal
          ; hidden_sort = spectec_terminal
          ; hidden_typ = typ
          ; hidden_witness = Const "synunknown"
          ; hidden_diagnostics =
              diagnostics
              @ [ unsupported
                    ~ctx ~origin
                    ~constructor:"VariantT/constructor/hidden-bind"
                    ~source_echo:(Il.Print.string_of_quant bind)
                    ~reason:
                      "hidden typcase ExpP binder could not lower its carrier or type witness"
                    ~suggestion:
                      "Keep this typcase Unsupported until the hidden binder type can be represented without guessing"
                    ()
                ]
          })
    | ExpP _ | TypP _ | DefP _ | GramP _ -> None)

let condition_admissibility_diagnostics ctx origin mixop initial_bound conditions =
  let _, diagnostics =
    conditions
    |> List.fold_left
         (fun (bound, diagnostics) condition ->
           match condition with
           | EqCond (lhs, rhs) ->
             let vars = term_free_vars lhs @ term_free_vars rhs in
             if vars_subset vars bound then
               bound, diagnostics
             else
               bound,
               diagnostics
               @ [ unsupported
                     ~ctx ~origin
                     ~constructor:"VariantT/constructor/premise/admissibility"
                     ~source_echo:(Il.Print.string_of_mixop mixop)
                     ~reason:
                       "equational typcase premise condition mentions variables that are not bound by the constructor head or earlier matching conditions"
                     ~suggestion:
                       "Introduce the variable through a source-derived MatchCond before using it in this condition"
                     ()
                 ]
           | BoolCond term | MembershipCond (term, _) ->
             let vars = term_free_vars term in
             if vars_subset vars bound then
               bound, diagnostics
             else
               bound,
               diagnostics
               @ [ unsupported
                     ~ctx ~origin
                     ~constructor:"VariantT/constructor/premise/admissibility"
                     ~source_echo:(Il.Print.string_of_mixop mixop)
                     ~reason:
                       "typcase premise condition mentions variables that are not bound by the constructor head or earlier matching conditions"
                     ~suggestion:
                       "Introduce the variable through a source-derived MatchCond before using it in this condition"
                     ()
                 ]
           | MatchCond (lhs, rhs) ->
             let rhs_vars = term_free_vars rhs in
             if vars_subset rhs_vars bound then
               add_bound_vars bound (term_free_vars lhs), diagnostics
             else
               bound,
               diagnostics
               @ [ unsupported
                     ~ctx ~origin
                     ~constructor:"VariantT/constructor/premise/admissibility"
                     ~source_echo:(Il.Print.string_of_mixop mixop)
                     ~reason:
                       "typcase matching condition would bind variables from a right-hand side that itself is not bound yet"
                     ~suggestion:
                       "Reorder or split the source-derived conditions before emitting this typcase"
                     ()
                 ])
         (initial_bound, [])
  in
  diagnostics

let condition_or_true (lowered : Expr_translate.result) =
  match lowered.term with
  | None -> None
  | Some (Const "true") -> Some lowered.guards
  | Some term -> Some (lowered.guards @ [ BoolCond term ])

let unsupported_typcase_prem ctx origin prem =
  unsupported
    ~ctx ~origin ~constructor:"VariantT/constructor/premise"
    ?source_echo:(source_echo_prem prem)
    ~reason:
      "only IfPr typcase premises can be preserved as constructor typecheck conditions in this slice"
    ~suggestion:
      "Route this premise through a source-preserving premise helper before emitting the constructor case"
    ()

let lower_hidden_bind_premise ctx visible_expr_env expr_env origin hidden rhs_exp residual_exps =
  let rhs =
    if
      List.mem
        (Maude_ir.sort_name hidden.hidden_sort)
        [ "Nat"; "Int"; "Rat" ]
    then
      Expr_translate.lower_numeric_guard_value ctx visible_expr_env origin rhs_exp
    else
      Expr_translate.lower_value ctx visible_expr_env origin rhs_exp
  in
  match rhs.term with
  | Some rhs_term ->
    let residual_conditions, residual_diagnostics =
      residual_exps
      |> List.fold_left
           (fun (conditions, diagnostics) residual_exp ->
             let lowered =
               Expr_translate.lower_bool_condition ctx expr_env origin residual_exp
             in
             match condition_or_true lowered with
             | Some residual_conditions ->
               conditions @ residual_conditions,
               diagnostics @ lowered.diagnostics
             | None ->
               conditions,
               diagnostics @ lowered.diagnostics
               @ [ unsupported
                     ~ctx ~origin ~constructor:"VariantT/constructor/hidden-bind/residual"
                     ~source_echo:(Il.Print.string_of_exp residual_exp)
                     ~reason:
                       "residual conjunct from hidden-binder premise did not lower to a Bool condition"
                     ~suggestion:
                       "Keep this typcase Unsupported until the residual premise can be preserved as a Maude condition"
                     ()
                 ])
           ([], [])
    in
    ( [ MatchCond (Var hidden.hidden_variable, rhs_term)
      ; BoolCond
          (typecheck_for_sort
             hidden.hidden_sort
             (Var hidden.hidden_variable)
             hidden.hidden_witness)
      ]
      @ rhs.guards
      @ residual_conditions
    , rhs.diagnostics @ residual_diagnostics )
  | None -> [], rhs.diagnostics

let lower_constructor_premises env ctx origin components hidden_binds prems =
  let visible_expr_env = expr_env_with_components env components in
  let expr_env = expr_env_with_hidden_binds visible_expr_env hidden_binds in
  prems
  |> List.fold_left
       (fun (conditions, diagnostics) prem ->
         let hidden_match =
           hidden_binds
           |> List.find_map (fun hidden ->
             hidden_bind_extract_from_prem hidden.hidden_source_id prem
             |> Option.map (fun (rhs, residuals) -> hidden, rhs, residuals))
         in
         match hidden_match with
         | Some (hidden, rhs_exp, residual_exps) ->
           let hidden_conditions, hidden_diagnostics =
             lower_hidden_bind_premise
               ctx visible_expr_env expr_env origin hidden rhs_exp residual_exps
           in
           conditions @ hidden_conditions, diagnostics @ hidden_diagnostics
         | None ->
           match prem.it with
           | IfPr exp ->
             let lowered = Expr_translate.lower_bool_condition ctx expr_env origin exp in
             (match condition_or_true lowered with
             | Some prem_conditions ->
               conditions @ prem_conditions, diagnostics @ lowered.diagnostics
             | None ->
               conditions,
               diagnostics @ lowered.diagnostics
               @ [ unsupported
                     ~ctx ~origin ~constructor:"VariantT/constructor/premise/IfPr"
                     ~source_echo:(Il.Print.string_of_prem prem)
                     ~reason:"typcase IfPr did not lower to a Bool condition"
                     ~suggestion:
                     "Extend expression Bool lowering before emitting this typcase premise"
                   ()
                ])
           | RulePr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ ->
             conditions, diagnostics @ [ unsupported_typcase_prem ctx origin prem ])
       ([], [])

type constructor_case_lowering =
  { constructor_name : string
  ; components : component list
  ; hidden_binds : hidden_exp_bind list
  ; membership_guards : eq_condition list
  ; dependent_guards : eq_condition list
  ; prem_conditions : eq_condition list
  ; projection_ops : string list
  ; diagnostics : Diagnostics.t list
  }

let describe_constructor_case
    ?(record_like_single_constructor = false)
    env
    ctx
    origin
    seed
    target
    mixop
    binds
    prems
    source_components
  =
  let constructor_name =
    Naming.constructor_op_in_category
      ~record_like_single_constructor
      (category_name_of_target target)
      mixop
  in
  let lowered_opt, diagnostics =
    lower_components env ctx origin "VariantT/constructor" seed source_components
  in
  match lowered_opt with
  | None -> None, diagnostics
  | Some components ->
    let hidden_binds =
      lower_hidden_exp_binds env ctx origin seed source_components prems binds
    in
    let hidden_diagnostics =
      hidden_binds
      |> List.map (fun hidden -> hidden.hidden_diagnostics)
      |> List.concat
    in
    let head_bound = List.map (fun component -> component.variable) components in
    let lhs_bound =
      List.fold_left
        (fun vars name -> if List.mem name vars then vars else name :: vars)
        head_bound
        (term_free_vars target)
    in
    let split_guard (membership_guards, dependent_guards, diagnostics) component =
      let guard_conditions, guard_condition_diagnostics =
        guard_conditions_for_typ
          env
          ctx
          origin
          "VariantT/constructor"
          component.typ
          component.sort
          (Var component.variable)
          component.witness
      in
      guard_conditions
      |> List.fold_left
           (fun (membership_guards, dependent_guards, diagnostics) guard_condition ->
             let guard_vars = condition_free_vars guard_condition in
             if vars_subset guard_vars head_bound then
               guard_condition :: membership_guards, dependent_guards, diagnostics
             else if vars_subset guard_vars lhs_bound then
               membership_guards, guard_condition :: dependent_guards, diagnostics
             else
               membership_guards,
               dependent_guards,
               diagnostics
               @ [ unsupported
                     ~ctx ~origin ~constructor:"VariantT/constructor/dependent-guard"
                     ~source_echo:(Il.Print.string_of_mixop mixop)
                     ~reason:
                       "constructor argument guard mentions variables that are not bound by the visible constructor arguments or target syntax witness"
                     ~suggestion:
                       "Keep this case Unsupported until the dependent guard can be represented without adding hidden constructor arguments"
                     ()
                 ])
           (membership_guards, dependent_guards, diagnostics @ guard_condition_diagnostics)
    in
    let membership_guards, dependent_guards, guard_diagnostics =
      components
      |> List.fold_left split_guard ([], [], [])
      |> fun (membership_guards, dependent_guards, diagnostics) ->
        List.rev membership_guards, List.rev dependent_guards, diagnostics
    in
    let prem_conditions, prem_diagnostics =
      lower_constructor_premises env ctx origin components hidden_binds prems
    in
    let condition_diagnostics =
      condition_admissibility_diagnostics ctx origin mixop lhs_bound prem_conditions
    in
    let projection_ops =
      components
      |> List.mapi (fun index _component ->
        Naming.destructor_op_in_category
          (category_name_of_target target)
          mixop
          index)
    in
    let lowering_diagnostics =
      diagnostics @ hidden_diagnostics @ guard_diagnostics @ prem_diagnostics
      @ condition_diagnostics
    in
    Some
      { constructor_name
      ; components
      ; hidden_binds
      ; membership_guards
      ; dependent_guards
      ; prem_conditions
      ; projection_ops
      ; diagnostics = lowering_diagnostics
      },
    lowering_diagnostics

let register_constructor_case ctx origin static_args_key target mixop lowering =
  let registry_status =
    if List.exists Diagnostics.is_fatal lowering.diagnostics then
      Constructor_registry.Unsupported
    else
      Constructor_registry.Emitted
  in
  register_constructor
    ctx origin
    ~status:registry_status
    ?static_args_key
    ~target
    ~mixop
    ~arity:(List.length lowering.components)
    ~constructor_op:lowering.constructor_name
    ~projection_ops:lowering.projection_ops
    ~payload_witnesses:(List.map (fun component -> component.witness) lowering.components)
    ()

let lower_constructor_case_for_registry
    ?(record_like_single_constructor = false)
    env
    ctx
    origin
    seed
    static_args_key
    target
    mixop
    binds
    prems
    source_components
  =
  match
    describe_constructor_case
      ~record_like_single_constructor
      env
      ctx
      origin
      seed
      target
      mixop
      binds
      prems
      source_components
  with
  | None, diagnostics -> None, diagnostics
  | Some lowering, diagnostics ->
    register_constructor_case ctx origin static_args_key target mixop lowering;
    Some lowering, diagnostics

let translate_constructor_case
    ?(record_like_single_constructor = false)
    env
    ctx
    origin
    seed
    static_args_key
    target
    mixop
    binds
    prems
    components
  =
  match
    lower_constructor_case_for_registry
      ~record_like_single_constructor
      env
      ctx
      origin
      seed
      static_args_key
      target
      mixop
      binds
      prems
      components
  with
  | None, diagnostics -> with_diagnostics diagnostics
  | Some lowering, lowering_diagnostics ->
    let components = lowering.components in
    let vars =
      components
      |> List.map (fun component -> gen origin (var component.variable (sr component.sort)))
    in
    let hidden_vars =
      lowering.hidden_binds
      |> List.map (fun hidden ->
        gen origin (var hidden.hidden_variable (sr hidden.hidden_sort)))
    in
    let args = List.map (fun component -> sr component.sort) components in
    let arg_terms = List.map (fun component -> Var component.variable) components in
    let constructor = app lowering.constructor_name arg_terms in
    let op_kind = if components = [] then Total else Partial in
    let op_decl =
      gen origin
        (op lowering.constructor_name args spectec_terminal ~kind:op_kind ~attrs:[ Ctor ])
    in
    let membership =
      match components with
      | [] -> []
      | _ -> [ gen origin (cmb constructor spectec_terminal lowering.membership_guards) ]
    in
    let destructors =
      List.combine lowering.projection_ops components
      |> List.map (fun (destructor, component) ->
        [ gen origin (op destructor [ sr spectec_terminal ] component.sort ~kind:Partial)
        ; gen origin
            (ceq
               (app destructor [ constructor ])
               (Var component.variable)
               [ MembershipCond (constructor, spectec_terminal) ])
        ])
      |> List.concat
    in
    if
      List.exists Diagnostics.is_fatal
        (lowering.diagnostics)
    then
      { statements = vars @ hidden_vars @ [ op_decl ] @ membership @ destructors
      ; diagnostics = lowering_diagnostics
      }
    else
      let typecheck_conditions =
        (match components with
        | [] -> []
        | _ -> [ MembershipCond (constructor, spectec_terminal) ])
        @ lowering.dependent_guards
        @ lowering.prem_conditions
      in
      let typecheck_statement =
        gen origin
          (ceq
             (typecheck constructor target)
             (Const "true")
             typecheck_conditions)
      in
      { statements =
          vars @ hidden_vars @ [ op_decl ] @ membership @ destructors
          @ [ typecheck_statement ]
      ; diagnostics = lowering_diagnostics
      }

let translate_typcase
    env
    ctx
    parent_origin
    seed
    key_env
    static_args_key
    target
    ~case_count
    index
    (mixop, (typ, binds, prems), hints)
  =
  let origin =
    child_origin
      parent_origin
      (Printf.sprintf "VariantT[%d]" index)
      "typcase"
      typ.at
      (source_echo_typcase (mixop, (typ, binds, prems), hints))
  in
  let owner = "VariantT/typcase" in
  let components = typ_components typ in
  let record_like_single_constructor =
    record_like_single_constructor_case ~case_count mixop components
  in
  let hint_pairs = hint_diagnostics ctx origin owner hints in
  let hint_blocks, hint_diags = List.split hint_pairs in
  if mixop_is_hole_only mixop then
    match numeric_predicate_from_typcase binds typ prems with
    | Some (payload_id, payload_typ, payload_sort, predicate)
      when not (List.exists Fun.id hint_blocks) ->
      append
        (translate_numeric_predicate_case
           env ctx origin seed static_args_key target mixop payload_id payload_typ payload_sort predicate)
        (with_diagnostics hint_diags)
    | Some _ ->
      with_diagnostics hint_diags
    | None ->
    match numeric_literal_terms_from_typcase binds typ prems with
    | Some (`Literals (payload_sort, literal_terms)) when not (List.exists Fun.id hint_blocks) ->
      append
        (translate_numeric_literal_case ctx origin seed static_args_key target mixop payload_sort literal_terms)
        (with_diagnostics hint_diags)
    | Some `Range ->
      with_diagnostics (hint_diags @ [ unsupported_numeric_range ctx origin (mixop, (typ, binds, prems), hints) ])
    | _ ->
      let components = typ_components typ in
      if List.length components > 1 || (components <> [] && (binds <> [] || prems <> [])) then
        let bind_diags =
          constructor_bind_diagnostics ctx origin owner binds components prems
        in
        let blocking =
          List.exists Diagnostics.is_fatal bind_diags || List.exists Fun.id hint_blocks
        in
        let diagnostics = bind_diags @ hint_diags in
        if blocking then
          with_diagnostics diagnostics
        else
          append
            (translate_constructor_case
               ~record_like_single_constructor
               env
               ctx
               origin
               seed
               static_args_key
               target
               mixop
               binds
               prems
               components)
            (with_diagnostics diagnostics)
      else
        let bind_diags = unsupported_binds ctx origin owner binds in
        let prem_diags = unsupported_prems ctx origin owner prems in
        let blocking =
          bind_diags <> [] || prem_diags <> [] || List.exists Fun.id hint_blocks
        in
        let diagnostics = bind_diags @ prem_diags @ hint_diags in
        (match components with
        | [ _payload, child_typ ] when not blocking ->
          append
            (translate_category_union env ctx origin seed key_env static_args_key target child_typ)
            (with_diagnostics diagnostics)
        | _ ->
          with_diagnostics
            (diagnostics
             @ [ unsupported
                   ~ctx ~origin ~constructor:"VariantT/hole-only-case"
                   ?source_echo:(source_echo_typcase (mixop, (typ, binds, prems), hints))
                   ~reason:
                     "hole-only typcase is a category union only when it has one supported type and no binds/premises; multi-component hole-only cases are tuple-style constructors"
                   ~suggestion:"Implement numeric range, extension metadata, or guarded subtype lowering before emitting this case"
                   ()
               ]))
  else
  let bind_diags = constructor_bind_diagnostics ctx origin owner binds components prems in
  let blocking =
    List.exists Diagnostics.is_fatal bind_diags || List.exists Fun.id hint_blocks
  in
  let diagnostics = bind_diags @ hint_diags in
  if blocking then
    with_diagnostics diagnostics
  else
    append
      (translate_constructor_case
         ~record_like_single_constructor
         env
         ctx
         origin
         seed
         static_args_key
         target
         mixop
         binds
         prems
         components)
      (with_diagnostics diagnostics)

let inherited_union_origin parent_origin index typcase =
  let _mixop, (typ, _binds, _prems), _hints = typcase in
  child_origin
    parent_origin
    (Printf.sprintf "VariantT[%d]/category-union" index)
    "typcase"
    typ.at
    (source_echo_typcase typcase)

let inherited_union_block env ctx parent_origin seed key_env static_args_key target group =
  match group with
  | [] -> empty
  | first :: _ ->
    let origin =
      inherited_union_origin
        parent_origin
        (first.inherited_index + 1)
        first.inherited_typcase
    in
    let child_typ = VarT (first.inherited_child_id, []) $ first.inherited_child_id.at in
    translate_category_union
      env
      ctx
      origin
      (seed ^ "U" ^ string_of_int (first.inherited_index + 1))
      key_env
      static_args_key
      target
      child_typ

let translate_variant env ctx origin seed key_env static_args_key target id cases =
  let inherited_groups =
    inherited_category_cases ctx id cases
    |> group_inherited_category_cases
  in
  let complete_groups, incomplete_groups =
    inherited_groups |> List.partition inherited_group_is_complete
  in
  let skip_indices = inherited_skip_indices complete_groups in
  let union_result =
    complete_groups
    |> List.map (inherited_union_block env ctx origin seed key_env static_args_key target)
    |> List.fold_left append empty
  in
  let incomplete_diagnostics =
    incomplete_groups
    |> List.map (unsupported_incomplete_inherited_group ctx origin id)
    |> List.concat
  in
  let case_result =
    cases
    |> List.mapi (fun index typcase ->
      if List.mem index skip_indices then
        empty
      else
        translate_typcase
          env
          ctx
          origin
          (seed ^ "C" ^ string_of_int (index + 1))
          key_env
          static_args_key
          target
          ~case_count:(List.length cases)
          (index + 1)
          typcase)
    |> List.fold_left append empty
  in
  append union_result case_result
  |> fun result -> { result with diagnostics = result.diagnostics @ incomplete_diagnostics }

let translate_struct_field env ctx origin seed index (atom, (typ, binds, prems), hints) =
  let field_origin =
    child_origin
      origin
      (Printf.sprintf "StructT[%d]" index)
      "typfield"
      typ.at
      (source_echo_typfield (atom, (typ, binds, prems), hints))
  in
  let owner = "StructT/typfield" in
  let components = typ_components typ in
  let bind_diags =
    constructor_bind_diagnostics ctx field_origin owner binds components prems
  in
  let prem_diags = unsupported_prems ctx field_origin owner prems in
  let hint_pairs = hint_diagnostics ctx field_origin owner hints in
  let hint_blocks, hint_diags = List.split hint_pairs in
  let bind_blocking = List.exists Diagnostics.is_fatal bind_diags in
  match components with
  | [ payload, typ ]
    when (not bind_blocking) && prem_diags = [] && not (List.exists Fun.id hint_blocks) ->
    let component =
      lower_component env ctx field_origin "StructT/field" seed index (payload, typ)
    in
    let payload_diags = payload_diagnostics ctx field_origin "StructT/field" payload in
    let _, sort_diags = carrier_sort_of_typ ctx field_origin "StructT/field" typ in
    let _, witness_diags = witness_of_typ env ctx field_origin "StructT/field" typ in
    (match component with
    | Some component ->
      Some (atom, component),
      bind_diags @ prem_diags @ hint_diags @ component.diagnostics
    | None ->
      None,
      bind_diags @ prem_diags @ hint_diags @ payload_diags @ sort_diags @ witness_diags)
  | _ ->
    None,
    bind_diags @ prem_diags @ hint_diags
    @ [ unsupported
          ~ctx ~origin:field_origin ~constructor:"StructT/field-shape"
          ?source_echo:(source_echo_typfield (atom, (typ, binds, prems), hints))
          ~reason:"record fields with zero or multiple tuple components require a tuple-preserving field encoding"
          ~suggestion:"Implement tuple field carriers before lowering this struct field"
          ()
      ]

let replace_nth index replacement values =
  values
  |> List.mapi (fun i value -> if i = index then replacement else value)

let translate_struct env ctx origin seed target id fields =
  let lowered, diagnostics =
    fields
    |> List.mapi (fun index field -> translate_struct_field env ctx origin seed (index + 1) field)
    |> List.split
  in
  let diagnostics = List.concat diagnostics in
  if List.for_all Option.is_some lowered then
    let fields = List.map Option.get lowered in
    let constructor_name = Naming.record_constructor id in
    let field_components = List.map snd fields in
    let field_terms = List.map (fun component -> Var component.variable) field_components in
    let record_term = app constructor_name field_terms in
    let op_decl =
      gen origin
        (op constructor_name
           (List.map (fun component -> sr component.sort) field_components)
           spectec_terminal
           ~kind:(if field_components = [] then Total else Partial)
           ~attrs:[ Ctor ])
    in
    let vars =
      field_components
      |> List.map (fun component -> gen origin (var component.variable (sr component.sort)))
    in
    let guards, guard_diagnostics =
      field_components
      |> List.fold_left
           (fun (guards, diagnostics) component ->
             let component_guards, component_diagnostics =
               guard_conditions_for_typ
                 env
                 ctx
                 origin
                 "StructT/field"
                 component.typ
                 component.sort
                 (Var component.variable)
                 component.witness
             in
             guards @ component_guards, diagnostics @ component_diagnostics)
           ([], [])
    in
    let membership =
      match field_components with
      | [] -> []
      | _ -> [ gen origin (cmb record_term spectec_terminal guards) ]
    in
    let typecheck_statement =
      match field_components with
      | [] -> gen origin (eq (typecheck record_term target) (Const "true"))
      | _ ->
        gen origin
          (ceq
             (typecheck record_term target)
             (Const "true")
             [ MembershipCond (record_term, spectec_terminal) ])
    in
    let accessor_and_updates =
      fields
      |> List.mapi (fun index (atom, component) ->
        let qid = Qid (qid_of_atom atom) in
        let replacement = var_name seed "UPD" (index + 1) in
        let replacement_decl = gen origin (var replacement (sr component.sort)) in
        let update_lhs =
          app "_[._<-_]" [ record_term; qid; Var replacement ]
        in
        let update_rhs =
          app constructor_name (replace_nth index (Var replacement) field_terms)
        in
        let update_eq = gen origin (eq update_lhs update_rhs) in
        [ gen origin
            (eq
               (app "value" [ qid; record_term ])
               (Var component.variable))
        ; replacement_decl
        ; update_eq
        ])
      |> List.concat
    in
    { statements =
        vars @ [ op_decl ] @ membership @ [ typecheck_statement ] @ accessor_and_updates
    ; diagnostics = diagnostics @ guard_diagnostics
    }
  else
    with_diagnostics diagnostics

let preload_alias_registry env ctx origin key_env static_args_key target typ =
  let carrier_opt, _carrier_diagnostics =
    carrier_sort_of_typ ctx origin "AliasT" typ
  in
  let witness_opt, _witness_diagnostics =
    witness_of_typ env ctx origin "AliasT" typ
  in
  match carrier_opt, witness_opt with
  | Some _carrier, Some witness ->
    register_category_inclusion
      ctx origin
      ~reason:"AliasT"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~target
      typ;
    let wrapper_constructor =
      Naming.wrapper_constructor_in_category (category_name_of_target target)
    in
    let destructor =
      Naming.destructor_op_in_category
        (category_name_of_target target)
        alias_projection_mixop
        0
    in
    register_constructor
      ctx origin
      ?static_args_key
      ~target
      ~mixop:alias_projection_mixop
      ~arity:1
      ~constructor_op:wrapper_constructor
      ~projection_ops:[ destructor ]
      ~payload_witnesses:[ witness ]
      ()
  | _ -> ()

let preload_category_union_registry env ctx origin key_env static_args_key target child_typ =
  let carrier_opt, _carrier_diagnostics =
    carrier_sort_of_typ ctx origin "VariantT/category-union" child_typ
  in
  let witness_opt, _witness_diagnostics =
    witness_of_typ env ctx origin "VariantT/category-union" child_typ
  in
  match carrier_opt, witness_opt with
  | Some _, Some _ ->
    register_category_inclusion
      ctx origin
      ~reason:"VariantT/category-union"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~target
      child_typ
  | _ -> ()

let preload_numeric_predicate_registry env ctx origin static_args_key target mixop payload_id payload_typ payload_sort predicate =
  let variable = Naming.maude_var ("PRELOAD_PRED_" ^ payload_id.it) in
  let variable_term = Var variable in
  let expr_env =
    Expr_translate.add_var
      (expr_env_of_static_env env)
      payload_id.it
      { Expr_translate.term = variable_term; sort = payload_sort; typ = payload_typ }
  in
  let lowered = Expr_translate.lower_bool_condition ctx expr_env origin predicate in
  match lowered.term with
  | Some _ -> ignore (register_numeric_wrapper ctx ~mixop origin static_args_key target)
  | None -> ()

let preload_inherited_union_registry env ctx parent_origin seed key_env static_args_key target group =
  match group with
  | [] -> ()
  | first :: _ ->
    let origin =
      inherited_union_origin
        parent_origin
        (first.inherited_index + 1)
        first.inherited_typcase
    in
    let child_typ = VarT (first.inherited_child_id, []) $ first.inherited_child_id.at in
    ignore seed;
    preload_category_union_registry env ctx origin key_env static_args_key target child_typ

let preload_typcase_registry
    env
    ctx
    parent_origin
    seed
    key_env
    static_args_key
    target
    ~case_count
    index
    (mixop, (typ, binds, prems), hints)
  =
  let origin =
    child_origin
      parent_origin
      (Printf.sprintf "VariantT[%d]" index)
      "typcase"
      typ.at
      (source_echo_typcase (mixop, (typ, binds, prems), hints))
  in
  let owner = "VariantT/typcase" in
  let components = typ_components typ in
  let record_like_single_constructor =
    record_like_single_constructor_case ~case_count mixop components
  in
  let hint_pairs = hint_diagnostics ctx origin owner hints in
  let hint_blocks, _hint_diags = List.split hint_pairs in
  if mixop_is_hole_only mixop then
    match numeric_predicate_from_typcase binds typ prems with
    | Some (payload_id, payload_typ, payload_sort, predicate)
      when not (List.exists Fun.id hint_blocks) ->
      preload_numeric_predicate_registry
        env ctx origin static_args_key target mixop payload_id payload_typ payload_sort predicate
    | Some _ -> ()
    | None ->
      (match numeric_literal_terms_from_typcase binds typ prems with
      | Some (`Literals (payload_sort, _literal_terms))
        when not (List.exists Fun.id hint_blocks) ->
        ignore payload_sort;
        ignore (register_numeric_wrapper ctx ~mixop origin static_args_key target)
      | Some `Range -> ()
      | _ ->
        if List.length components > 1 || (components <> [] && (binds <> [] || prems <> [])) then
          let bind_diags =
            constructor_bind_diagnostics ctx origin owner binds components prems
          in
          let blocking =
            List.exists Diagnostics.is_fatal bind_diags || List.exists Fun.id hint_blocks
          in
          if not blocking then
            ignore
              (lower_constructor_case_for_registry
                 ~record_like_single_constructor
                 env
                 ctx
                 origin
                 seed
                 static_args_key
                 target
                 mixop
                 binds
                 prems
                 components)
        else
          let bind_diags = unsupported_binds ctx origin owner binds in
          let prem_diags = unsupported_prems ctx origin owner prems in
          let blocking =
            bind_diags <> [] || prem_diags <> [] || List.exists Fun.id hint_blocks
          in
          (match components with
          | [ _payload, child_typ ] when not blocking ->
            preload_category_union_registry env ctx origin key_env static_args_key target child_typ
          | _ -> ()))
  else
    let bind_diags = constructor_bind_diagnostics ctx origin owner binds components prems in
    let blocking =
      List.exists Diagnostics.is_fatal bind_diags || List.exists Fun.id hint_blocks
    in
    if not blocking then
      ignore
        (lower_constructor_case_for_registry
           ~record_like_single_constructor
           env
           ctx
           origin
           seed
           static_args_key
           target
           mixop
           binds
           prems
           components)

let preload_variant_registry env ctx origin seed key_env static_args_key target id cases =
  let inherited_groups =
    inherited_category_cases ctx id cases
    |> group_inherited_category_cases
  in
  let complete_groups, _incomplete_groups =
    inherited_groups |> List.partition inherited_group_is_complete
  in
  let skip_indices = inherited_skip_indices complete_groups in
  complete_groups
  |> List.iter (preload_inherited_union_registry env ctx origin seed key_env static_args_key target);
  cases
  |> List.iteri (fun index typcase ->
    if not (List.mem index skip_indices) then
      preload_typcase_registry
        env
        ctx
        origin
        (seed ^ "C" ^ string_of_int (index + 1))
        key_env
        static_args_key
        target
        ~case_count:(List.length cases)
        (index + 1)
        typcase)

let preload_deftyp_registry env ctx origin seed key_env static_args_key target id deftyp =
  match deftyp.it with
  | AliasT typ -> preload_alias_registry env ctx origin key_env static_args_key target typ
  | VariantT cases -> preload_variant_registry env ctx origin seed key_env static_args_key target id cases
  | StructT _fields -> ()

let translate_deftyp env ctx origin seed key_env static_args_key target id deftyp =
  match deftyp.it with
  | AliasT typ -> translate_alias env ctx origin seed key_env static_args_key target typ
  | VariantT cases -> translate_variant env ctx origin seed key_env static_args_key target id cases
  | StructT fields -> translate_struct env ctx origin seed target id fields

type typd_setup =
  { seed : string
  ; witness_name : string
  ; supported_params : param list
  ; unsupported_static_params : param list
  ; param_refs : type_ref list
  ; param_var_decls : generated list
  ; env : static_env
  ; param_terms : term list
  ; diagnostics : Diagnostics.t list
  }

let prepare_typd ctx origin id params =
  let seed = stable_seed origin id.it in
  let witness_name = Naming.category_witness id in
  let supported_params, unsupported_static_params =
    params
    |> List.partition (fun param ->
      match param.it with
      | ExpP _ | TypP _ -> true
      | DefP _ | GramP _ -> false)
  in
  let param_ref_opts, param_ref_diags =
    supported_params
    |> List.map (param_type_ref ctx origin)
    |> List.split
  in
  let param_refs = List.filter_map Fun.id param_ref_opts in
  let static_param_diags =
    unsupported_static_params
    |> List.map (static_param_diagnostic ctx origin)
  in
  let param_bindings =
    supported_params
    |> List.mapi (fun index param -> param_binding ctx origin seed (index + 1) param)
  in
  let param_var_decls, env_updates, param_terms, param_binding_diags =
    List.fold_right
      (fun (decl, update, term, diagnostics) (decls, updates, terms, diags) ->
        decl :: decls, update :: updates, term :: terms, diagnostics :: diags)
      param_bindings
      ([], [], [], [])
  in
  let env =
    List.fold_left (fun env update -> update env) { exp_vars = []; typ_vars = [] } env_updates
  in
  { seed
  ; witness_name
  ; supported_params
  ; unsupported_static_params
  ; param_refs
  ; param_var_decls
  ; env
  ; param_terms
  ; diagnostics =
      static_param_diags
      @ List.concat param_ref_diags
      @ List.concat param_binding_diags
  }

module Inst_prepare = struct

type preload_state =
  | Preloadable
  | Emit_only

type ready =
  { ready_origin : Origin.t
  ; ready_seed : string
  ; ready_env : static_env
  ; ready_bind_statements : generated list
  ; ready_target : term
  ; ready_key_env : Static_key.env
  ; ready_static_args_key : string option
  ; ready_deftyp : deftyp
  ; ready_diagnostics : Diagnostics.t list
  ; ready_preload_state : preload_state
  }

type blocked =
  { blocked_origin : Origin.t
  ; blocked_seed : string
  ; blocked_diagnostics : Diagnostics.t list
  }

type t =
  | Ready of ready
  | Blocked of blocked

let prepare env ctx typ_origin seed witness_name param_terms id params index inst =
  let origin =
    child_origin
      typ_origin
      (Printf.sprintf "InstD[%d]" index)
      "InstD"
      inst.at
      (Some (Il.Print.string_of_inst id inst))
  in
  let inst_seed = seed ^ "I" ^ string_of_int index in
  match inst.it with
  | InstD (binds, args, deftyp) ->
    let inst_env, bind_statements, bind_diags =
      translate_inst_binds ctx origin inst_seed env binds
    in
    let target_terms, arg_diags =
      match args with
      | [] -> Some param_terms, []
      | _ -> terms_of_args inst_env ctx origin args
    in
    let target =
      target_terms |> Option.map (target_witness witness_name)
    in
    let key_env, key_env_diags =
      match bind_diags, target_terms, args with
      | _ :: _, _, _ | _, None, _ -> None, []
      | [], Some _, [] -> Some Static_key.empty, []
      | [], Some _, _ ->
        (match Static_key.of_params_args params args with
        | Ok key_env -> Some key_env, []
        | Error reason ->
          None,
          [ unsupported
              ~ctx ~origin ~constructor:"TypD/InstD/static-key"
              ?source_echo:(Some (Il.Print.string_of_inst id inst))
              ~reason
              ~suggestion:
                "Keep this instance Unsupported until its static parameters can be matched with concrete finite arguments"
              ()
          ])
    in
    let diagnostics = bind_diags @ arg_diags @ key_env_diags in
    match target, key_env with
    | Some target, Some key_env when bind_diags = [] && key_env_diags = [] ->
      let static_args_key =
        match args with
        | [] -> None
        | _ -> Static_key.of_args ~env:key_env args
      in
      let preload_state =
        match arg_diags with
        | [] -> Preloadable
        | _ :: _ -> Emit_only
      in
      Ready
        { ready_origin = origin
        ; ready_seed = inst_seed
        ; ready_env = inst_env
        ; ready_bind_statements = bind_statements
        ; ready_target = target
        ; ready_key_env = key_env
        ; ready_static_args_key = static_args_key
        ; ready_deftyp = deftyp
        ; ready_diagnostics = diagnostics
        ; ready_preload_state = preload_state
        }
    | _ ->
      Blocked
        { blocked_origin = origin
        ; blocked_seed = inst_seed
        ; blocked_diagnostics = diagnostics
        }

end

let translate_prepared_inst ctx id prepared =
  match prepared with
  | Inst_prepare.Ready ready ->
    let translated =
      translate_deftyp
        ready.Inst_prepare.ready_env
        ctx
        ready.Inst_prepare.ready_origin
        ready.Inst_prepare.ready_seed
        ready.Inst_prepare.ready_key_env
        ready.Inst_prepare.ready_static_args_key
        ready.Inst_prepare.ready_target
        id
        ready.Inst_prepare.ready_deftyp
    in
    append
      { translated with
        statements = ready.Inst_prepare.ready_bind_statements @ translated.statements
      }
      (with_diagnostics ready.Inst_prepare.ready_diagnostics)
  | Inst_prepare.Blocked blocked ->
    with_diagnostics blocked.Inst_prepare.blocked_diagnostics

let translate_inst env ctx typ_origin seed witness_name param_terms id params index inst =
  Inst_prepare.prepare env ctx typ_origin seed witness_name param_terms id params index inst
  |> translate_prepared_inst ctx id

let preload_inst_registry ctx origin id setup index inst =
  let prepared =
    Inst_prepare.prepare
      setup.env
      ctx
      origin
      setup.seed
      setup.witness_name
      setup.param_terms
      id
      setup.supported_params
      (index + 1)
      inst
  in
  match prepared with
  | Inst_prepare.Ready ready
    when ready.Inst_prepare.ready_preload_state = Inst_prepare.Preloadable ->
    preload_deftyp_registry
      ready.Inst_prepare.ready_env
      ctx
      ready.Inst_prepare.ready_origin
      ready.Inst_prepare.ready_seed
      ready.Inst_prepare.ready_key_env
      ready.Inst_prepare.ready_static_args_key
      ready.Inst_prepare.ready_target
      id
      ready.Inst_prepare.ready_deftyp
  | Inst_prepare.Ready _ | Inst_prepare.Blocked _ -> ()

let preload_typd_registry ctx origin id params insts =
  let setup = prepare_typd ctx origin id params in
  match setup.unsupported_static_params with
  | [] ->
    insts |> List.iteri (preload_inst_registry ctx origin id setup)
  | _ :: _ -> ()

let translate_typd ctx origin id params insts =
  let setup = prepare_typd ctx origin id params in
  let witness_decl = gen origin (op setup.witness_name setup.param_refs spectec_type) in
  let inst_result =
    match setup.unsupported_static_params with
    | [] ->
      insts
      |> List.mapi (fun index inst ->
        translate_inst
          setup.env
          ctx
          origin
          setup.seed
          setup.witness_name
          setup.param_terms
          id
          setup.supported_params
          (index + 1)
          inst)
      |> List.fold_left append empty
    | _ :: _ -> empty
  in
  { statements = witness_decl :: setup.param_var_decls @ inst_result.statements
  ; diagnostics = setup.diagnostics @ inst_result.diagnostics
  }
