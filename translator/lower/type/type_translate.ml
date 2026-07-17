open Il.Ast
open Maude_ir
open Util.Source

open Type_diagnostic
open Type_result

let sr = sort_ref
let spectec_terminal = sort "SpectecTerminal"
let spectec_type = sort "SpectecType"
let app name args = App (name, args)
let gen origin node = generated ~origin node

let condition_free_vars = function
  | EqCond (left, right) | MatchCond (left, right) ->
    Condition_closure.term_vars left @ Condition_closure.term_vars right
  | MembershipCond (term, _) | BoolCond term ->
    Condition_closure.term_vars term

let rec payload_source_id exp =
  match exp.it with
  | VarE id when id.it <> "_" -> Some id.it
  | IterE (body, ((List | Opt), [ generator_id, source_exp ]))
    when iter_body_preserves_generator generator_id.it body ->
    payload_source_id source_exp
  | LiftE inner ->
    (match inner.it with
    | IterE ({ it = VarE body_id; _ }, (Opt, [ generator_id, source_exp ]))
      when body_id.it = generator_id.it ->
      (match source_exp.it with
      | VarE source_id when source_id.it <> "_" -> Some source_id.it
      | _ -> None)
    | _ -> None)
  | SubE (inner, _, _) -> payload_source_id inner
  | _ -> None

and payload_source_matches expected exp =
  match payload_source_id exp with
  | Some id -> id = expected
  | None -> false

and iter_body_preserves_generator generator body =
  match body.it with
  | VarE id -> id.it = generator
  | IterE (inner, ((List | Opt), [ inner_generator, source_exp ])) ->
    payload_source_matches generator source_exp
    && iter_body_preserves_generator inner_generator.it inner
  | LiftE inner | SubE (inner, _, _) ->
    iter_body_preserves_generator generator inner
  | _ -> false

let qid_of_atom atom = Xl.Atom.to_string atom

let typd_carrier ctx origin constructor typ =
  match Carrier_sort.for_typd ctx typ with
  | Ok sort -> Some sort, []
  | Error error ->
    None, [ unsupported_carrier ~ctx ~origin ~constructor typ error ]

type result = Type_result.result =
  { statements : generated list
  ; diagnostics : Diagnostics.t list
  }

type component =
  { variable : string
  ; sort : sort
  ; typ : typ
  ; source_id : string option
  ; witness : term
  ; diagnostics : Diagnostics.t list
  }

type hidden_exp_bind =
  { hidden_source_id : string
  ; hidden_variable : string
  ; hidden_sort : sort
  ; hidden_typ : typ
  ; hidden_witness : term
  ; hidden_diagnostics : Diagnostics.t list
  }

let payload_matches_exp_bind bind_id (payload, _typ) =
  match payload_source_id payload with
  | Some payload_id -> payload_id = bind_id.it
  | None -> false

let exp_mentions_var id exp =
  Il.Free.Set.mem id (Il.Free.free_exp exp).varid

let rec exp_is_var id exp =
  match exp.it with
  | VarE var_id -> var_id.it = id
  | SubE (inner, _, _) | CvtE (inner, _, _) -> exp_is_var id inner
  | _ -> false

let hidden_bind_rhs_from_equality bind_id left right =
  if exp_is_var bind_id left && not (exp_mentions_var bind_id right) then
    Some right
  else if exp_is_var bind_id right && not (exp_mentions_var bind_id left) then
    Some left
  else
    None

let rec hidden_bind_extract_from_exp bind_id exp =
  match exp.it with
  | CmpE (`EqOp, _, left, right) ->
    hidden_bind_rhs_from_equality bind_id left right
    |> Option.map (fun rhs -> rhs, [])
  | BinE (`AndOp, _, left, right) ->
    (match
       hidden_bind_extract_from_exp bind_id left,
       hidden_bind_extract_from_exp bind_id right
     with
    | Some (rhs, residuals), None -> Some (rhs, residuals @ [ right ])
    | None, Some (rhs, residuals) -> Some (rhs, left :: residuals)
    | None, None | Some _, Some _ -> None)
  | _ -> None

let hidden_bind_extract_from_prem bind_id prem =
  match prem.it with
  | IfPr exp -> hidden_bind_extract_from_exp bind_id exp
  | LetPr (_quants, lhs, rhs) ->
    hidden_bind_rhs_from_equality bind_id lhs rhs
    |> Option.map (fun rhs -> rhs, [])
  | RulePr _ | ElsePr | IterPr _ | NegPr _ -> None

let hidden_exp_bind_supported bind_id components prems =
  not (List.exists (payload_matches_exp_bind bind_id) components)
  && List.exists
       (fun prem -> Option.is_some (hidden_bind_extract_from_prem bind_id.it prem))
       prems

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

let translate_inst_binds ctx origin env binds =
  let names =
    let sources =
      binds
      |> List.filter_map (fun bind ->
        match bind.it with
        | ExpP (id, _) | TypP id when id.it <> "_" -> Some id.it
        | ExpP _ | TypP _ | DefP _ | GramP _ -> None)
    in
    Type_static_env.reserve_static_env Local_name.empty env
    |> fun names -> Local_name.reserve_sources names sources
  in
  binds
  |> List.fold_left
       (fun (env, statements, diagnostics) bind ->
         match bind.it with
         | TypP id ->
           (match Type_static_env.find_typ env id.it with
           | Some _ -> env, statements, diagnostics
           | None ->
             let term =
               Local_name.source_qualified names id.it (sr spectec_type)
             in
             Type_static_env.add_typ env id.it term,
             statements,
             diagnostics)
         | ExpP (id, typ) ->
           (match Type_static_env.find_exp env id.it with
           | Some _ -> env, statements, diagnostics
           | None ->
             let sort_opt, sort_diags =
               typd_carrier ctx origin "TypD/InstD/binds/ExpP" typ
             in
             (match sort_opt with
             | Some sort ->
               let term = Local_name.source_qualified names id.it (sr sort) in
               let binding =
                 { Type_static_env.static_term = term
                 ; static_sort = sort
                 ; static_typ = typ
                 }
               in
               Type_static_env.add_exp env id.it binding,
               statements,
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

let variable_name = function
  | Var name -> name
  | Const _ | Qid _ | App _ ->
    invalid_arg "Type_translate.variable_name: expected Maude variable"

let component_names env target binds components =
  (* Repeated component labels do not assert equality; equality is an explicit
     source premise.  Reserve only hidden binders here and name each occurrence. *)
  let component_sources =
    components |> List.filter_map (fun (payload, _) -> payload_source_id payload)
  in
  let hidden_sources =
    binds
    |> List.filter_map (fun bind ->
      match bind.it with
      | ExpP (id, _) | TypP id
        when id.it <> "_" && not (List.mem id.it component_sources) ->
        Some id.it
      | ExpP _ | TypP _ | DefP _ | GramP _ -> None)
  in
  Type_static_env.reserve_static_env Local_name.empty env
  |> fun names ->
     Local_name.reserve_existing_many names (Condition_closure.term_vars target)
  |> fun names -> Local_name.reserve_sources names hidden_sources

let lower_component env ctx origin constructor names (payload, typ) =
  let payload_diagnostics =
    payload_diagnostics ctx origin constructor payload
  in
  let sort_opt, sort_diagnostics = typd_carrier ctx origin constructor typ in
  let witness_opt, witness_diagnostics =
    Typd_witness.of_typ env ctx origin ~constructor typ
  in
  match payload_diagnostics, sort_opt, witness_opt with
  | _ :: _, _, _ -> None, names
  | [], Some sort, Some witness ->
    let source_id = payload_source_id payload in
    let variable, names =
      match source_id with
      | Some id -> Local_name.fresh_source_qualified names id (sr sort)
      | None -> Local_name.fresh_qualified names Local_name.Component (sr sort)
    in
    Some
      { variable = variable_name variable
      ; sort
      ; typ
      ; source_id
      ; witness
      ; diagnostics = payload_diagnostics @ sort_diagnostics @ witness_diagnostics
      }, names
  | [], _, _ -> None, names

let component_diagnostics env ctx origin constructor (payload, typ) =
  let payload_diags = payload_diagnostics ctx origin constructor payload in
  let _, sort_diags = typd_carrier ctx origin constructor typ in
  let _, witness_diags = Typd_witness.of_typ env ctx origin ~constructor typ in
  payload_diags @ sort_diags @ witness_diags

let env_with_component env component =
  match component.source_id with
  | None -> env
  | Some id ->
    let binding =
      { Type_static_env.static_term = Var component.variable
      ; static_sort = component.sort
      ; static_typ = component.typ
      }
    in
    Type_static_env.add_exp env id binding

let lower_components env ctx origin constructor names components =
  let _env, lowered_rev, diagnostics, failed, names =
    components
     |> List.fold_left
         (fun (env, lowered_rev, diagnostics, failed, names) component ->
           match lower_component env ctx origin constructor names component with
           | Some lowered, names ->
             env_with_component env lowered,
             lowered :: lowered_rev,
             diagnostics @ lowered.diagnostics,
             failed,
             names
           | None, names ->
             env,
             lowered_rev,
             diagnostics @ component_diagnostics env ctx origin constructor component,
             true,
             names)
         (env, [], [], false, names)
  in
  if failed then None, diagnostics, names
  else Some (List.rev lowered_rev), diagnostics, names

let exp_param_sort ctx origin typ =
  let sort_opt, diagnostics = typd_carrier ctx origin "TypD/param/ExpP" typ in
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

let param_binding ctx origin names param =
  let type_ref, diagnostics =
    match param_type_ref ctx origin param with
    | Some type_ref, diagnostics -> type_ref, diagnostics
    | None, _ ->
      param_binding_invariant param
        "parameter has no Maude runtime type reference"
  in
  let term =
    match param.it with
    | ExpP (id, _) | TypP id ->
      Local_name.source_qualified names id.it type_ref
    | DefP _ | GramP _ ->
      param_binding_invariant param
        "static DefP/GramP must be rejected before runtime parameter binding"
  in
  let env_update env =
    match param.it with
    | ExpP (id, typ) ->
      let sort, _diagnostics = exp_param_sort ctx origin typ in
      let binding =
        { Type_static_env.static_term = term
        ; static_sort = sort
        ; static_typ = typ
        }
      in
      Type_static_env.add_exp env id.it binding
    | TypP id -> Type_static_env.add_typ env id.it term
    | DefP _ | GramP _ ->
      param_binding_invariant param
        "static DefP/GramP cannot update runtime expression/type environments"
  in
  env_update, term, diagnostics

let target_witness witness_name args =
  app witness_name args

let translate_alias
    env ctx origin key_env static_args_key source_category target typ =
  Type_alias.translate_alias
    env ctx origin key_env static_args_key source_category target typ

module Variant = struct

let translate_category_union
    env ctx origin key_env static_args_key source_category target child_typ =
  Type_alias.translate_category_union
    env ctx origin key_env static_args_key source_category target child_typ

let expr_env_with_components env components =
  components
  |> List.fold_left
       (fun expr_env component ->
         match component.source_id with
         | None -> expr_env
         | Some id ->
           Expr_env.add
             expr_env
             id
             { Expr_env.term = Var component.variable
             ; sort = component.sort
             ; typ = component.typ
             })
       (Type_static_env.to_expr_env env)

let expr_env_with_hidden_binds expr_env hidden_binds =
  hidden_binds
  |> List.fold_left
       (fun expr_env hidden ->
         Expr_env.add
           expr_env
           hidden.hidden_source_id
           { Expr_env.term = Var hidden.hidden_variable
           ; sort = hidden.hidden_sort
           ; typ = hidden.hidden_typ
           })
       expr_env

let lower_hidden_exp_binds env ctx origin names components prems binds =
  binds
  |> List.fold_left (fun (hidden, names) bind ->
    match bind.it with
    | ExpP (id, typ)
      when hidden_exp_bind_supported id components prems ->
      let sort_opt, sort_diags =
        typd_carrier ctx origin "VariantT/constructor/hidden-bind" typ
      in
      let witness_opt, witness_diags =
        Typd_witness.of_typ
          env ctx origin ~constructor:"VariantT/constructor/hidden-bind" typ
      in
      let diagnostics = sort_diags @ witness_diags in
      (match sort_opt, witness_opt with
      | Some sort, Some witness ->
        let variable = Local_name.source_qualified names id.it (sr sort) in
        { hidden_source_id = id.it
          ; hidden_variable = variable_name variable
          ; hidden_sort = sort
          ; hidden_typ = typ
          ; hidden_witness = witness
          ; hidden_diagnostics = diagnostics
          } :: hidden, names
      | _ ->
        let variable =
          Local_name.source_qualified names id.it (sr spectec_terminal)
        in
        { hidden_source_id = id.it
          ; hidden_variable = variable_name variable
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
          } :: hidden, names)
    | ExpP _ | TypP _ | DefP _ | GramP _ -> hidden, names)
       ([], names)
  |> fun (hidden, names) -> List.rev hidden, names

let condition_or_true (lowered : Expr_result.result) =
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
          (Typecheck_term.typecheck_for_sort
             hidden.hidden_sort
             (Var hidden.hidden_variable)
             hidden.hidden_witness)
      ]
      @ rhs.guards
      @ residual_conditions
    , rhs.diagnostics @ residual_diagnostics )
  | None -> [], rhs.diagnostics

let lower_constructor_premises env ctx origin category_id components hidden_binds prems =
  let visible_expr_env = expr_env_with_components env components in
  let expr_env = expr_env_with_hidden_binds visible_expr_env hidden_binds in
  prems
  |> List.mapi (fun index prem -> index + 1, prem)
  |> List.fold_left
       (fun (conditions, diagnostics) (index, prem) ->
         match
           Runtime_ingress_validation.find
             (Context.runtime_ingress_validation ctx)
             ~category_id
             prem
         with
         | Some discharge ->
           let prem_origin =
             child_origin origin
               (Printf.sprintf "IfPr[%d]" index)
               "IfPr"
               prem.at
               (source_echo_prem prem)
           in
           let declaration_text = String.concat ", " discharge.declarations in
           conditions,
           diagnostics
           @ [ skipped
                 ~ctx ~origin:prem_origin
                 ~constructor:"VariantT/constructor/premise/IfPr/runtime-ingress"
                 ?source_echo:(source_echo_prem prem)
                 ~reason:
                   ("The validated runtime configuration admits this syntax category only through parser/decoder ingress; its well-formedness IfPr calls clause-free non-builtin DecD declaration(s) used nowhere outside ingress-only TypD premises, binds no runtime variable, and is therefore discharged: "
                    ^ declaration_text)
                 ~suggestion:
                   "Keep the source premise and declaration in provenance; emit no runtime condition unless the category becomes synthesized or the declaration gains another use or a source clause"
                 ()
             ]
         | None ->
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
  ; construction_domain : Constructor_registry.construction_domain
  }

let length_guarded_representation origin source_components prems =
  match source_components, prems with
  | [ payload, _ ], [ ({ it = IfPr condition; _ } as prem) ] ->
    (match condition.it with
    | CmpE (`LtOp, `NatT, { it = LenE observed; _ }, bound)
      when payload_source_id payload = payload_source_id observed
           && Option.is_some (payload_source_id payload)
           && Il.Free.Set.is_empty (Il.Free.free_exp bound).varid ->
      Some
        (Constructor_registry.Length_guarded_representation_constructor
           { payload_index = 0
           ; closed_bound = bound
           ; guard_origin =
               Origin.with_child
                 ~source_echo:(Il.Print.string_of_prem prem)
                 origin "length-guard"
                 ~ast_constructor:"IfPr(CmpE/Lt/Nat/LenE)" prem.at
           })
    | _ -> None)
  | _ -> None

let describe_constructor_case
    ?(record_like_single_constructor = false)
    env
    ctx
    origin
    source_category
    target
    mixop
    binds
    prems
    source_components
  =
  let constructor_name =
    Naming.constructor_op_in_category
      ~record_like_single_constructor
      source_category
      mixop
  in
  let names = component_names env target binds source_components in
  let lowered_opt, diagnostics, names =
    lower_components env ctx origin "VariantT/constructor" names source_components
  in
  match lowered_opt with
  | None -> None, diagnostics
  | Some components ->
    let hidden_binds, _names =
      lower_hidden_exp_binds env ctx origin names source_components prems binds
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
        (Condition_closure.term_vars target)
    in
    let split_guard (membership_guards, dependent_guards, diagnostics) component =
      let guard_conditions =
        Typecheck_guard.for_typ
          component.typ component.sort (Var component.variable) component.witness
      in
      guard_conditions
      |> List.fold_left
           (fun (membership_guards, dependent_guards, diagnostics) guard_condition ->
             let guard_vars = condition_free_vars guard_condition in
             if Condition_closure.vars_subset guard_vars head_bound then
               guard_condition :: membership_guards, dependent_guards, diagnostics
             else if Condition_closure.vars_subset guard_vars lhs_bound then
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
           (membership_guards, dependent_guards, diagnostics)
    in
    let membership_guards, dependent_guards, guard_diagnostics =
      components
      |> List.fold_left split_guard ([], [], [])
      |> fun (membership_guards, dependent_guards, diagnostics) ->
        List.rev membership_guards, List.rev dependent_guards, diagnostics
    in
    let prem_conditions, prem_diagnostics =
      lower_constructor_premises
        env ctx origin source_category components hidden_binds prems
    in
    let condition_diagnostics =
      Condition_admissibility.typcase_premise_admissibility_diagnostics
        ctx origin mixop lhs_bound prem_conditions
    in
    let projection_ops =
      components
      |> List.mapi (fun index _component ->
        Naming.destructor_op_in_category
          source_category
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
      ; construction_domain =
          (match hidden_binds, dependent_guards, prem_conditions with
          | [], [], [] -> Constructor_registry.Total_constructor
          | [], _, []
            when Type_shape.mixop_is_hole_only mixop
                 && List.length components = 1 ->
            Constructor_registry.Certified_representation_constructor
          | [], _, _
            when binds = []
                 && Type_shape.mixop_is_hole_only mixop
                 && List.length components = 1 ->
            (match length_guarded_representation origin source_components prems with
            | Some certificate -> certificate
            | None ->
              Constructor_registry.Guarded_constructor
                (Printf.sprintf
                   "source typcase retains hidden binds=%d, dependent guards=%d, premise conditions=%d"
                   (List.length hidden_binds)
                   (List.length dependent_guards)
                   (List.length prem_conditions)))
          | _ ->
            Constructor_registry.Guarded_constructor
              (Printf.sprintf
                 "source typcase retains hidden binds=%d, dependent guards=%d, premise conditions=%d"
                 (List.length hidden_binds)
                 (List.length dependent_guards)
                 (List.length prem_conditions)))
      },
    lowering_diagnostics

let register_constructor_case
    ctx origin static_args_key source_category mixop lowering =
  let registry_status =
    if List.exists Diagnostics.is_fatal lowering.diagnostics then
      Constructor_registry.Unsupported
    else
      Constructor_registry.Emitted
  in
  let payload_label component =
    match component.typ.it with
    | VarT (id, _) -> Constructor_registry.Source_category id.it
    | BoolT -> Constructor_registry.Primitive_type "bool"
    | NumT typ -> Constructor_registry.Primitive_type (Xl.Num.string_of_typ typ)
    | TextT -> Constructor_registry.Primitive_type "text"
    | TupT _ | IterT _ -> Constructor_registry.Structural_payload
  in
  Typd_registry.register_constructor
    ctx origin
    ~status:registry_status
    ~construction_domain:lowering.construction_domain
    ?static_args_key
    ~source_category
    ~mixop
    ~arity:(List.length lowering.components)
    ~constructor_op:lowering.constructor_name
    ~projection_ops:lowering.projection_ops
    ~payload_labels:(List.map payload_label lowering.components)
    ~payload_witnesses:(List.map (fun component -> component.witness) lowering.components)
    ~payload_sorts:(List.map (fun component -> component.sort) lowering.components)
    ()

let lower_constructor_case_for_registry
    ?(record_like_single_constructor = false)
    env
    ctx
    origin
    static_args_key
    source_category
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
      source_category
      target
      mixop
      binds
      prems
      source_components
  with
  | None, diagnostics -> None, diagnostics
  | Some lowering, diagnostics ->
    let registration =
      register_constructor_case
        ctx origin static_args_key source_category mixop lowering
    in
    let registry_diagnostic reason =
      unsupported
        ~ctx ~origin
        ~constructor:"VariantT/constructor/resolved-registry"
        ~source_echo:(Il.Print.string_of_mixop mixop)
        ~reason
        ~suggestion:
          "Preload this exact source category/static-key/mixop/arity owner before resolving constructor surfaces"
        ()
    in
    (match registration with
    | Constructor_registry.Rejected_after_resolution ->
      None,
      diagnostics
      @ [ registry_diagnostic
            "a genuinely new constructor entry was rejected after constructor surface resolution"
        ]
    | Constructor_registry.Registered
    | Constructor_registry.Already_registered ->
    (match
       Constructor_registry.lookup_at_origin
         (Context.constructors ctx)
         ~source_category
         ~static_args_key
         ~mixop
         ~arity:(List.length lowering.components)
         ~origin
     with
    | Found entry ->
      Some
        { lowering with
          constructor_name = entry.constructor_op
        ; projection_ops = entry.projection_ops
      },
      diagnostics
    | Missing ->
      None,
      diagnostics
      @ [ registry_diagnostic
            "resolved constructor lookup found no exact source owner; unresolved statements were suppressed"
        ]
    | Ambiguous entries ->
      None,
      diagnostics
      @ [ registry_diagnostic
            (Printf.sprintf
               "resolved constructor lookup found %d exact source-owner candidates; unresolved statements were suppressed"
               (List.length entries))
        ]))

let translate_constructor_case
    ?(record_like_single_constructor = false)
    env
    ctx
    origin
    static_args_key
    source_category
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
      static_args_key
      source_category
      target
      mixop
      binds
      prems
      components
  with
  | None, diagnostics -> with_diagnostics diagnostics
  | Some lowering, lowering_diagnostics ->
    let components = lowering.components in
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
      { statements = [ op_decl ] @ membership @ destructors
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
             (Typecheck_term.typecheck constructor target)
             (Const "true")
             typecheck_conditions)
      in
      { statements =
          [ op_decl ] @ membership @ destructors
          @ [ typecheck_statement ]
      ; diagnostics = lowering_diagnostics
      }

let translate_typcase
    env
    ctx
    parent_origin
    key_env
    static_args_key
    source_category
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
  let components = Type_shape.typ_components typ in
  let record_like_single_constructor =
    record_like_single_constructor_case ~case_count mixop components
  in
  let hint_pairs = hint_diagnostics ctx origin owner hints in
  let hint_blocks, hint_diags = List.split hint_pairs in
  if Type_shape.mixop_is_hole_only mixop then
    match numeric_predicate_from_typcase binds typ prems with
    | Some (payload_id, payload_typ, payload_sort, predicate)
      when not (List.exists Fun.id hint_blocks) ->
      append
        (translate_numeric_predicate_case
           env ctx origin static_args_key source_category target mixop
           payload_id payload_typ payload_sort predicate)
        (with_diagnostics hint_diags)
    | Some _ ->
      with_diagnostics hint_diags
    | None ->
    match numeric_literal_terms_from_typcase binds typ prems with
    | Some (`Literals (payload_sort, literal_terms)) when not (List.exists Fun.id hint_blocks) ->
      append
        (translate_numeric_literal_case
           env ctx origin static_args_key source_category target mixop
           payload_sort literal_terms)
        (with_diagnostics hint_diags)
    | Some `Range ->
      with_diagnostics (hint_diags @ [ unsupported_numeric_range ctx origin (mixop, (typ, binds, prems), hints) ])
    | _ ->
      let components = Type_shape.typ_components typ in
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
               static_args_key
               source_category
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
            (translate_category_union
               env ctx origin key_env static_args_key source_category
               target child_typ)
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
         static_args_key
         source_category
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

let inherited_union_block
    env ctx parent_origin key_env static_args_key source_category target group =
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
      key_env
      static_args_key
      source_category
      target
      child_typ

let subtype_inclusion_origin parent_origin child_id =
  child_origin
    parent_origin
    ("VariantT/subtype/" ^ child_id.it)
    "category-inclusion"
    child_id.at
    (Some (child_id.it ^ " <: parent"))

let subtype_inclusion_block env ctx parent_origin target child_id =
  let origin = subtype_inclusion_origin parent_origin child_id in
  let child_typ = VarT (child_id, []) $ child_id.at in
  Type_alias.translate_subtype_membership
    env ctx origin target child_typ

let translate_variant
    env ctx origin key_env static_args_key target id target_region cases =
  let source_category = Naming.source_owner id.it in
  let inherited_groups =
    inherited_category_cases ctx id target_region cases
    |> group_inherited_category_cases
  in
  let complete_groups, incomplete_groups =
    inherited_groups |> List.partition inherited_group_is_complete
  in
  let complete_groups = maximal_inherited_groups ctx complete_groups in
  let incomplete_groups =
    incomplete_groups
    |> List.filter (fun group ->
      not (incomplete_group_is_covered complete_groups group))
  in
  let skip_indices = inherited_skip_indices complete_groups in
  let inherited_children =
    complete_groups |> List.filter_map inherited_group_child
  in
  let subtype_children =
    subtype_category_children ctx id
    |> List.filter (fun child ->
      not (List.exists (fun inherited -> child.it = inherited.it) inherited_children))
  in
  let union_result =
    complete_groups
    |> List.map
         (inherited_union_block
            env ctx origin key_env static_args_key source_category target)
    |> List.fold_left append empty
  in
  let subtype_result =
    subtype_children
    |> List.map
         (subtype_inclusion_block env ctx origin target)
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
          key_env
          static_args_key
          source_category
          target
          ~case_count:(List.length cases)
          (index + 1)
          typcase)
    |> List.fold_left append empty
  in
  append union_result (append subtype_result case_result)
  |> fun result -> { result with diagnostics = result.diagnostics @ incomplete_diagnostics }

let preload_category_union_registry
    env ctx origin key_env static_args_key source_category child_typ =
  let carrier_opt, _carrier_diagnostics =
    typd_carrier ctx origin "VariantT/category-union" child_typ
  in
  let witness_opt, _witness_diagnostics =
    Typd_witness.of_typ
      env ctx origin ~constructor:"VariantT/category-union" child_typ
  in
  match carrier_opt, witness_opt with
  | Some _, Some _ ->
    Typd_registry.register_inclusion
      ctx origin
      ~reason:"VariantT/category-union"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~parent_category:source_category
      child_typ
  | _ -> ()

let preload_numeric_predicate_registry
    env ctx origin static_args_key source_category target mixop
    payload_id payload_typ payload_sort predicate =
  let variable_term =
    Type_static_env.reserve_static_env Local_name.empty env
    |> fun names -> Local_name.reserve_sources names [ payload_id.it ]
    |> fun names -> Local_name.source_qualified names payload_id.it (sr payload_sort)
  in
  let expr_env =
    Expr_env.add
      (Type_static_env.to_expr_env env)
      payload_id.it
      { Expr_env.term = variable_term; sort = payload_sort; typ = payload_typ }
  in
  let lowered = Expr_translate.lower_bool_condition ctx expr_env origin predicate in
  match lowered.term with
  | Some _ ->
    ignore
      (register_numeric_wrapper
         ctx
         ~mixop
         origin
         static_args_key
         source_category
         target
         payload_sort)
  | None -> ()

let preload_inherited_union_registry
    env ctx parent_origin key_env static_args_key source_category group =
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
    preload_category_union_registry
      env ctx origin key_env static_args_key source_category child_typ

let preload_typcase_registry
    env
    ctx
    parent_origin
    key_env
    static_args_key
    source_category
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
  let components = Type_shape.typ_components typ in
  let record_like_single_constructor =
    record_like_single_constructor_case ~case_count mixop components
  in
  let hint_pairs = hint_diagnostics ctx origin owner hints in
  let hint_blocks, _hint_diags = List.split hint_pairs in
  if Type_shape.mixop_is_hole_only mixop then
    match numeric_predicate_from_typcase binds typ prems with
    | Some (payload_id, payload_typ, payload_sort, predicate)
      when not (List.exists Fun.id hint_blocks) ->
      preload_numeric_predicate_registry
        env ctx origin static_args_key source_category target mixop
        payload_id payload_typ payload_sort predicate
    | Some _ -> ()
    | None ->
      (match numeric_literal_terms_from_typcase binds typ prems with
      | Some (`Literals (payload_sort, _literal_terms))
        when not (List.exists Fun.id hint_blocks) ->
        ignore
          (register_numeric_wrapper
             ctx
             ~mixop
             origin
             static_args_key
             source_category
             target
             payload_sort)
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
                 static_args_key
                 source_category
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
            preload_category_union_registry
              env ctx origin key_env static_args_key source_category child_typ
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
           static_args_key
           source_category
           target
           mixop
           binds
           prems
           components)

let preload_variant_registry
    env ctx origin key_env static_args_key target id target_region cases =
  let source_category = Naming.source_owner id.it in
  cases
  |> List.iteri (fun index ((_, (typ, _, _), _) as typcase) ->
    let case_origin =
      child_origin
        origin
        (Printf.sprintf "VariantT[%d]" (index + 1))
        "typcase"
        typ.at
        (source_echo_typcase typcase)
    in
    Constructor_registry.note_source_case
      (Context.constructors ctx)
      ~source_category
      ~static_args_key
      case_origin);
  let inherited_groups =
    inherited_category_cases ctx id target_region cases
    |> group_inherited_category_cases
  in
  let complete_groups, _incomplete_groups =
    inherited_groups |> List.partition inherited_group_is_complete
  in
  let complete_groups = maximal_inherited_groups ctx complete_groups in
  let skip_indices = inherited_skip_indices complete_groups in
  complete_groups
  |> List.iter
       (preload_inherited_union_registry
          env ctx origin key_env static_args_key source_category);
  cases
  |> List.iteri (fun index typcase ->
    if not (List.mem index skip_indices) then
      preload_typcase_registry
        env
        ctx
        origin
        key_env
        static_args_key
        source_category
        target
        ~case_count:(List.length cases)
        (index + 1)
        typcase)


end

module Struct = struct

let translate_struct_field env ctx origin names index (atom, (typ, binds, prems), hints) =
  let field_origin =
    child_origin
      origin
      (Printf.sprintf "StructT[%d]" index)
      "typfield"
      typ.at
      (source_echo_typfield (atom, (typ, binds, prems), hints))
  in
  let owner = "StructT/typfield" in
  let components = Type_shape.typ_components typ in
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
    let component, names =
      lower_component env ctx field_origin "StructT/field" names (payload, typ)
    in
    let payload_diags = payload_diagnostics ctx field_origin "StructT/field" payload in
    let _, sort_diags = typd_carrier ctx field_origin "StructT/field" typ in
    let _, witness_diags =
      Typd_witness.of_typ
        env ctx field_origin ~constructor:"StructT/field" typ
    in
    (match component with
    | Some component ->
      Some (atom, component),
      bind_diags @ prem_diags @ hint_diags @ component.diagnostics,
      names
    | None ->
      None,
      bind_diags @ prem_diags @ hint_diags @ payload_diags @ sort_diags @ witness_diags,
      names)
  | _ ->
    None,
    bind_diags @ prem_diags @ hint_diags
    @ [ unsupported
          ~ctx ~origin:field_origin ~constructor:"StructT/field-shape"
          ?source_echo:(source_echo_typfield (atom, (typ, binds, prems), hints))
          ~reason:"record fields with zero or multiple tuple components require a tuple-preserving field encoding"
          ~suggestion:"Implement tuple field carriers before lowering this struct field"
          ()
      ],
    names

let replace_nth index replacement values =
  values
  |> List.mapi (fun i value -> if i = index then replacement else value)

let option_all items =
  if List.for_all Option.is_some items then
    Some (List.filter_map Fun.id items)
  else
    None

let record_composition_term plan left right =
  match plan with
  | Record_certificate.Append -> app "_ _" [ left; right ]
  | Record_certificate.Compose_optional -> app "composeOpt" [ left; right ]
  | Record_certificate.Compose_record nested ->
    app
      (Naming.record_composition (Record_certificate.plan_id nested))
      [ left; right ]

let rec record_composition_fields names fields plans =
  match fields, plans with
  | [], [] -> Some ([], [], []), names
  | (atom, component) :: fields, plan :: plans ->
    let atom_name = qid_of_atom atom in
    let left, names =
      Local_name.fresh_source_qualified
        names ("LEFT_" ^ atom_name) (sr component.sort)
    in
    let right, names =
      Local_name.fresh_source_qualified
        names ("RIGHT_" ^ atom_name) (sr component.sort)
    in
    (match record_composition_fields names fields plans with
    | Some (lefts, rights, results), names ->
      Some
        ( left :: lefts
        , right :: rights
        , record_composition_term plan left right :: results )
      , names
    | None, names -> None, names)
  | _ -> None, names

let record_composition_statements origin names fields plan =
  let id = Record_certificate.plan_id plan in
  let plans = Record_certificate.plan_fields plan |> List.map snd in
  match record_composition_fields names fields plans with
  | None, _ -> None
  | Some (lefts, rights, results), _ ->
    let constructor = Naming.record_constructor id in
    let left = app constructor lefts in
    let right = app constructor rights in
    let result = app constructor results in
    let composition = app (Naming.record_composition id) [ left; right ] in
    let declaration =
      gen origin
        (op (Naming.record_composition id)
           [ sr spectec_terminal; sr spectec_terminal ]
           spectec_terminal ~kind:Partial)
    in
    let equation =
      match fields with
      | [] -> gen origin (eq composition result)
      | _ ->
        gen origin
          (ceq composition result
             [ MembershipCond (left, spectec_terminal)
             ; MembershipCond (right, spectec_terminal)
             ])
    in
    Some [ declaration; equation ]

let record_surface_diagnostic ctx origin source_fields conflict =
  unsupported
    ~ctx ~origin ~constructor:"TypD/StructT/record-surface"
    ~source_echo:
      (source_fields
       |> List.filter_map source_echo_typfield
       |> String.concat ", ")
    ~reason:(Record_certificate.describe_conflict conflict)
    ~suggestion:
      "Ensure every specialization sharing this canonical StructT surface has identical field identities, carriers, and recursive composition plan"
    ()

let record_helper_invariant_diagnostic ctx origin id reason =
  unsupported
    ~ctx ~origin ~constructor:"TypD/StructT/composition-helper-invariant"
    ~reason:
      ("composition helper `" ^ Naming.record_composition id ^ "` " ^ reason)
    ~suggestion:
      "Keep this StructT unsupported until its canonical record certificate and helper plan agree"
    ()

let materialize_record_composition ctx origin names fields plan =
  let certificates = Context.record_certificates ctx in
  match Record_certificate.helper_status certificates plan with
  | Record_certificate.Helper_emitted -> [], []
  | Record_certificate.Helper_unavailable _ ->
    let missing = Record_certificate.missing_dependencies certificates plan in
    if missing <> [] then (
      Record_certificate.note_helper_unavailable certificates plan missing;
      [], [])
    else
      (match record_composition_statements origin names fields plan with
      | Some statements ->
        Record_certificate.note_helper_emitted certificates plan;
        statements, []
      | None ->
        [],
        [ record_helper_invariant_diagnostic
            ctx origin (Record_certificate.plan_id plan)
            "has a field arity inconsistent with its lowered constructor"
        ])
  | Record_certificate.Helper_missing ->
    [],
    [ record_helper_invariant_diagnostic
        ctx origin (Record_certificate.plan_id plan)
        "was requested before its record surface was registered"
    ]
  | Record_certificate.Helper_incompatible ->
    [],
    [ record_helper_invariant_diagnostic
        ctx origin (Record_certificate.plan_id plan)
        "does not match the registered specialized StructT plan"
    ]

let translate_struct env ctx origin target id source_fields =
  let all_components =
    source_fields
    |> List.concat_map (fun (_, (typ, _, _), _) -> Type_shape.typ_components typ)
  in
  let all_binds =
    source_fields |> List.concat_map (fun (_, (_, binds, _), _) -> binds)
  in
  let names = component_names env target all_binds all_components in
  let lowered, diagnostics, names =
    source_fields
    |> List.mapi (fun index field -> index + 1, field)
    |> List.fold_left
         (fun (lowered, diagnostics, names) (index, field) ->
           let field, field_diagnostics, names =
             translate_struct_field env ctx origin names index field
           in
           field :: lowered, field_diagnostics :: diagnostics, names)
         ([], [], names)
    |> fun (lowered, diagnostics, names) ->
      List.rev lowered, List.rev diagnostics, names
  in
  let diagnostics = List.concat diagnostics in
  match option_all lowered with
  | Some fields ->
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
    let guards =
      field_components
      |> List.fold_left
           (fun guards component ->
             let component_guards =
               Typecheck_guard.for_typ
                 component.typ component.sort (Var component.variable) component.witness
             in
             guards @ component_guards)
           []
    in
    let membership =
      match field_components with
      | [] -> []
      | _ -> [ gen origin (cmb record_term spectec_terminal guards) ]
    in
    let typecheck_statement =
      match field_components with
      | [] -> gen origin (eq (Typecheck_term.typecheck record_term target) (Const "true"))
      | _ ->
        gen origin
          (ceq
             (Typecheck_term.typecheck record_term target)
             (Const "true")
             [ MembershipCond (record_term, spectec_terminal) ])
    in
    let accessor_and_updates, names =
      fields
      |> List.mapi (fun index (atom, component) ->
        index, atom, component)
      |> List.fold_left (fun (statements, names) (index, atom, component) ->
        let qid = Qid (qid_of_atom atom) in
        let replacement, names =
          Local_name.fresh_qualified names Local_name.Update (sr component.sort)
        in
        let update_lhs =
          app "_[._<-_]" [ record_term; qid; replacement ]
        in
        let update_rhs =
          app constructor_name (replace_nth index replacement field_terms)
        in
        let update_eq = gen origin (eq update_lhs update_rhs) in
        statements
        @ [ gen origin
              (eq
                 (app "value" [ qid; record_term ])
                 (Var component.variable))
          ; update_eq
          ],
        names)
           ([], names)
    in
    let composition =
      let shape : Record_shape.t = { id; fields = source_fields } in
      match Record_shape.composition ctx shape with
      | Ok plan -> Some plan
      | Error _ -> None
    in
    let surface_statements =
      [ op_decl ] @ membership @ [ typecheck_statement ] @ accessor_and_updates
    in
    let composition_surface =
      match composition with
      | None -> []
      | Some plan ->
        record_composition_statements origin names fields plan
        |> Option.value ~default:[]
    in
    let definition =
      Record_certificate.definition
        ~origin ~id
        ~fields:
          (fields
           |> List.map (fun (atom, component) -> atom, component.sort))
        ~composition
        ~surface:
          ((surface_statements @ composition_surface)
           |> List.map (fun statement -> statement.node))
    in
    let emit_registered_surface record_statements =
      let composition_statements, composition_diagnostics =
        match composition with
        | None -> [], []
        | Some plan ->
          materialize_record_composition ctx origin names fields plan
      in
      { statements = record_statements @ composition_statements
      ; diagnostics = diagnostics @ composition_diagnostics
      }
    in
    (match
       Record_certificate.register (Context.record_certificates ctx) definition
     with
    | Record_certificate.Conflict conflict ->
      { statements = []
      ; diagnostics =
          diagnostics @ [ record_surface_diagnostic ctx origin source_fields conflict ]
      }
    | Record_certificate.Fresh -> emit_registered_surface surface_statements
    | Record_certificate.Duplicate -> emit_registered_surface [])
  | None ->
    with_diagnostics diagnostics

end

let preload_alias_inclusion
    env ctx origin key_env static_args_key source_category typ =
  let carrier_opt, _carrier_diagnostics =
    typd_carrier ctx origin "AliasT" typ
  in
  let witness_opt, _witness_diagnostics =
    Typd_witness.of_typ env ctx origin ~constructor:"AliasT" typ
  in
  match carrier_opt, witness_opt with
  | Some _, Some _ ->
    Typd_registry.register_inclusion
      ctx origin
      ~reason:"AliasT"
      ~key_env
      ?parent_static_args_key:static_args_key
      ~parent_category:source_category
      typ
  | _ -> ()


let preload_deftyp_registry env ctx origin key_env static_args_key target id deftyp =
  let source_category = Naming.source_owner id.it in
  match deftyp.it with
  | AliasT typ ->
    preload_alias_inclusion
      env ctx origin key_env static_args_key source_category typ
  | VariantT cases ->
    Variant.preload_variant_registry
      env ctx origin key_env static_args_key target id deftyp.at cases
  | StructT _fields -> ()

let translate_deftyp env ctx origin key_env static_args_key target id deftyp =
  let source_category = Naming.source_owner id.it in
  match deftyp.it with
  | AliasT typ ->
    translate_alias
      env ctx origin key_env static_args_key source_category target typ
  | VariantT cases ->
    Variant.translate_variant
      env ctx origin key_env static_args_key target id deftyp.at cases
  | StructT fields -> Struct.translate_struct env ctx origin target id fields

type typd_setup =
  { witness_name : string
  ; supported_params : param list
  ; unsupported_static_params : param list
  ; param_refs : type_ref list
  ; env : Type_static_env.static_env
  ; param_terms : term list
  ; diagnostics : Diagnostics.t list
  }

let prepare_typd ctx origin id params =
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
    let names =
      supported_params
      |> List.filter_map (fun param ->
        match param.it with
        | ExpP (id, _) | TypP id -> Some id.it
        | DefP _ | GramP _ -> None)
      |> Local_name.reserve_sources Local_name.empty
    in
    supported_params |> List.map (param_binding ctx origin names)
  in
  let env_updates, param_terms, param_binding_diags =
    List.fold_right
      (fun (update, term, diagnostics) (updates, terms, diags) ->
        update :: updates, term :: terms, diagnostics :: diags)
      param_bindings
      ([], [], [])
  in
  let env =
    List.fold_left (fun env update -> update env) Type_static_env.empty env_updates
  in
  { witness_name
  ; supported_params
  ; unsupported_static_params
  ; param_refs
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
  ; ready_env : Type_static_env.static_env
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
  ; blocked_diagnostics : Diagnostics.t list
  }

type t =
  | Ready of ready
  | Blocked of blocked

let prepare env ctx typ_origin witness_name param_terms id params index inst =
  let origin =
    child_origin
      typ_origin
      (Printf.sprintf "InstD[%d]" index)
      "InstD"
      inst.at
      (Some (Il.Print.string_of_inst id inst))
  in
  match inst.it with
  | InstD (binds, args, deftyp) ->
    let inst_env, bind_statements, bind_diags =
      translate_inst_binds ctx origin env binds
    in
    let target_terms, arg_diags =
      match args with
      | [] -> Some param_terms, []
      | _ -> Typd_witness.terms_of_args inst_env ctx origin args
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

let translate_inst env ctx typ_origin witness_name param_terms id params index inst =
  Inst_prepare.prepare env ctx typ_origin witness_name param_terms id params index inst
  |> translate_prepared_inst ctx id

let preload_inst_registry ctx origin id setup index inst =
  let prepared =
    Inst_prepare.prepare
      setup.env
      ctx
      origin
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
          setup.witness_name
          setup.param_terms
          id
          setup.supported_params
          (index + 1)
          inst)
      |> List.fold_left append empty
    | _ :: _ -> empty
  in
  { statements = witness_decl :: inst_result.statements
  ; diagnostics = setup.diagnostics @ inst_result.diagnostics
  }
