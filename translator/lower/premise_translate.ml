open Il.Ast
open Maude_ir
open Util.Source

open Premise_capture
include Premise_result

let unsupported ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let skipped ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Skipped
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let source_echo_prem prem =
  Il.Print.string_of_prem prem

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let origin_for_premise parent prem =
  Origin.with_child
    ~source_echo:(source_echo_prem prem)
    parent
    "premise"
    ~ast_constructor:"Premise"
    prem.at

let origin_for_if_conjunct parent segment exp =
  Origin.with_child
    ~source_echo:(Il.Print.string_of_exp exp)
    parent
    segment
    ~ast_constructor:"IfPr/BinE"
    exp.at

let unsupported_prem ctx env ~bound_vars origin constructor prem reason =
  { (empty_with_env ~bound_vars env) with
    diagnostics =
      [ unsupported
          ~ctx ~origin ~constructor
          ~source_echo:(source_echo_prem prem)
          ~reason
          ~suggestion:"Keep this premise as Unsupported until the generic lowering rule is implemented"
          ()
      ]
  }

let unsupported_rulepr_args ctx env ~bound_vars origin prem rel_id args =
  unsupported_prem
    ctx
    env
    ~bound_vars
    origin
    "Premise/RulePr/args"
    prem
    ("relation premise `"
     ^ rel_id.it
     ^ "` carries explicit RulePr arguments `"
     ^ Il.Print.string_of_args args
     ^ "`, but relation-argument instantiation is not lowered yet; keep the args in the IL path instead of silently dropping them")

let skipped_prem ctx env ~bound_vars origin constructor prem reason suggestion =
  { (empty_with_env ~bound_vars env) with
    diagnostics =
      [ skipped
          ~ctx ~origin ~constructor
          ~source_echo:(source_echo_prem prem)
          ~reason
          ~suggestion
          ()
      ]
  }

let add_vars vars bound =
  vars
  |> List.fold_left
       (fun bound var -> if List.mem var bound then bound else var :: bound)
       bound

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let condition_bound_vars bound = function
  | EqCond _ | MembershipCond _ | BoolCond _ -> bound
  | MatchCond (pattern, _subject) -> add_vars (Condition_closure.term_vars pattern) bound

let conditions_bound_vars initial_bound conditions =
  conditions |> List.fold_left condition_bound_vars initial_bound

let with_conditions env bound_vars conditions diagnostics =
  { (empty_with_env
       ~bound_vars:(conditions_bound_vars bound_vars conditions)
       env)
    with
    eq_conditions = conditions
  ; diagnostics
  }

let take_match_binding var conditions =
  let rec loop acc = function
    | [] -> None
    | MatchCond (Var actual, term) :: rest when actual = var ->
      Some (term, List.rev_append acc rest)
    | condition :: rest -> loop (condition :: acc) rest
  in
  loop [] conditions

let rec is_direct_var_exp var exp =
  match exp.it with
  | VarE id -> id.it = var
  | OptE (Some inner) -> is_direct_var_exp var inner
  | _ -> false

let result_metadata
    (left : Expr_translate.result)
    (right : Expr_translate.result)
  =
  left.guards @ right.guards, left.diagnostics @ right.diagnostics

let result_has_fatal (result : Expr_translate.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let diagnostics_have_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let premise_result_has_fatal result =
  diagnostics_have_fatal result.diagnostics

let result_is_deferrable_listn_admissibility result =
  result.diagnostics
  |> List.exists (fun diagnostic ->
    Diagnostics.is_fatal diagnostic
    && diagnostic.Diagnostics.constructor = "Expr/IterE/ListN/premise-admissibility")

let typ_is_iter = Type_shape.typ_is_iter

let flat_optional_element_typ typ =
  match typ.it with
  | IterT (element_typ, Opt) when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let flat_list_element_typ typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let zip_source_descriptor typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some (Helper.Source_flat_terminal, element_typ)
  | IterT (({ it = IterT (element_typ, List); _ } as inner_list_typ),
           (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some (Helper.Source_nested_seq, inner_list_typ)
  | _ -> None

let app name args =
  App (name, args)

let sequence_concat left right =
  app "_ _" [ left; right ]

let is_opt term =
  app "isOpt" [ term ]

let pattern_result_has_fatal (result : Expr_translate.pattern_result) =
  List.exists Diagnostics.is_fatal result.pattern_diagnostics

let target_id ids id =
  match ids with
  | None -> true
  | Some ids -> List.exists (( = ) id) ids

let add_introduced_bindings ?ids env bindings =
  bindings
  |> List.fold_left
       (fun env (id, binding) ->
         if target_id ids id then
           Expr_translate.add_var env id binding
         else
           env)
       env

let try_match_condition
    ~bound
    (pattern_result : Expr_translate.pattern_result)
    (subject_result : Expr_translate.result)
  =
  match pattern_result.pattern_term, subject_result.term with
  | Some pattern, Some subject ->
    let guard_bound =
      conditions_bound_vars bound subject_result.guards
    in
    if
      (not (pattern_result_has_fatal pattern_result))
      && (not (result_has_fatal subject_result))
      && vars_subset (Condition_closure.term_vars subject) guard_bound
    then
      let conditions =
        subject_result.guards @ [ MatchCond (pattern, subject) ] @ pattern_result.pattern_guards
      in
      Some
        ( conditions
        , subject_result.diagnostics @ pattern_result.pattern_diagnostics )
    else
      None
  | _ -> None

let try_eq_condition left_result right_result =
  match
    (left_result : Expr_translate.result).term,
    (right_result : Expr_translate.result).term
  with
  | Some left, Some right ->
    if result_has_fatal left_result || result_has_fatal right_result then
      None
    else
      let guards, diagnostics = result_metadata left_result right_result in
      Some (guards @ [ EqCond (left, right) ], diagnostics)
  | _ -> None

let invert_unbound_unary_projection_condition ctx bound condition =
  let inverse projection_op scrutinee payload =
    match scrutinee with
    | Var name when not (List.mem name bound) ->
      (match
         Constructor_registry.lookup_unary_projection
           (Context.constructors ctx)
           ~projection_op
       with
      | Constructor_registry.Projection_found entry ->
        Some
          (MatchCond
             ( Var name
             , app entry.Constructor_registry.constructor_op [ payload ] ))
      | Constructor_registry.Projection_missing
      | Constructor_registry.Projection_ambiguous _ -> None)
    | _ -> None
  in
  match condition with
  | EqCond (App (projection_op, [ scrutinee ]), payload) ->
    (match inverse projection_op scrutinee payload with
    | Some condition -> condition
    | None -> condition)
  | EqCond (payload, App (projection_op, [ scrutinee ])) ->
    (match inverse projection_op scrutinee payload with
    | Some condition -> condition
    | None -> condition)
  | EqCond _ -> condition
  | MatchCond _ | MembershipCond _ | BoolCond _ -> condition

let invert_unbound_unary_projection_conditions ctx bound conditions =
  let step (bound, conditions) condition =
    let condition =
      invert_unbound_unary_projection_condition ctx bound condition
    in
    let bound = conditions_bound_vars bound [ condition ] in
    bound, conditions @ [ condition ]
  in
  conditions |> List.fold_left step (bound, []) |> snd

let try_record_match_condition ~bound pattern_result subject_result =
  try_match_condition ~bound pattern_result subject_result

let lower_bool_premise ctx env ~bound_vars origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  match lowered.term with
  | Some term ->
    with_conditions env bound_vars (lowered.guards @ [ BoolCond term ]) lowered.diagnostics
  | None -> { (empty_with_env ~bound_vars env) with diagnostics = lowered.diagnostics }

let typecheck_for_sort sort value typ =
  if sort_name sort = "SpectecTerminals" then
    App ("typecheckSeq", [ value; typ ])
  else
    App ("typecheck", [ value; typ ])

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let lower_with_source_carrier ctx env origin exp =
  match Expr_translate.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    Expr_translate.lower_sequence ctx env origin exp
  | _ -> Expr_translate.lower_value ctx env origin exp

let category_named_var ctx id =
  Analysis.Source_index.find_by_id (Context.source_index ctx) id.it
  |> List.find_map (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | TypD (typ_id, [], _) when typ_id.it = id.it ->
        Some (Const (Naming.category_witness id))
      | _ -> None)

let binding_is_bound bound_vars (binding : Expr_translate.binding) =
  Condition_closure.term_vars binding.term
  |> List.for_all (fun var -> List.mem var bound_vars)

let source_category_witness ctx env ~bound_vars exp =
  match exp.it with
  | VarE id when Expr_translate.find_var env id.it = None ->
    category_named_var ctx id
  | SubE ({ it = VarE id; _ }, { it = VarT (typ_id, []); _ }, _)
    when id.it = typ_id.it
         && (match Expr_translate.find_var env id.it with
             | None -> true
             | Some binding -> not (binding_is_bound bound_vars binding)) ->
    category_named_var ctx id
  | _ -> None

let lower_category_membership_eq_premise ctx env ~bound_vars origin value_exp category_exp =
  match source_category_witness ctx env ~bound_vars category_exp with
  | None -> None
  | Some witness ->
    let value_result = Expr_translate.lower_value ctx env origin value_exp in
    let sort_opt = Expr_translate.carrier_sort_of_typ value_exp.note in
    Some
      (match value_result.term, sort_opt with
      | Some value_term, Some value_sort ->
        let condition =
          BoolCond (typecheck_for_sort value_sort value_term witness)
        in
        with_conditions
          env
          bound_vars
          (value_result.guards @ [ condition ])
          value_result.diagnostics
      | _ ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = value_result.guards
        ; diagnostics = value_result.diagnostics
        })

type inverse_arg =
  | Inverse_known of Maude_ir.term
  | Inverse_target of string * Expr_translate.binding

type binding_map_target =
  { target_generator : id
  ; target_source_id : id
  ; target_source_exp : exp
  ; target_source_term : Maude_ir.term
  ; target_source_binding : Expr_translate.binding
  ; target_element_typ : typ
  ; target_element_sort : Maude_ir.sort
  }

let call_target_id ctx id =
  match Context.find_static_def ctx id.it with
  | Some target_id -> { id with it = target_id }
  | None -> id

let definition_has_only_runtime_params definition =
  definition.Analysis.Function_graph.params
  |> List.for_all (function
    | Analysis.Function_graph.Runtime_exp -> true
    | Static_typ | Static_def | Static_gram -> false)

let unbound_direct_var env ~bound_vars exp =
  match exp.it with
  | VarE id ->
    (match Expr_translate.find_var env id.it with
    | None -> Some id
    | Some binding when not (binding_is_bound bound_vars binding) -> Some id
    | Some _ -> None)
  | _ -> None

let unbound_env_var_binding env ~bound_vars exp =
  match exp.it with
  | VarE id ->
    (match Expr_translate.find_var env id.it with
    | Some binding when not (binding_is_bound bound_vars binding) ->
      Some (id.it, binding)
    | Some _ | None -> None)
  | _ -> None

let typed_var_for_exp id exp =
  match Expr_translate.carrier_sort_of_typ exp.note with
  | None -> None
  | Some sort ->
    let term = Var (Naming.maude_var id.it ^ ":" ^ sort_name sort) in
    Some (term, { Expr_translate.term; sort; typ = exp.note })

let same_sort left right =
  sort_name left = sort_name right

let unbound_var_binding env ~bound_vars exp =
  match exp.it with
  | VarE id ->
    let typed_binding =
      typed_var_for_exp id exp |> Option.map snd
    in
    (match Expr_translate.find_var env id.it with
    | Some binding when not (binding_is_bound bound_vars binding) ->
      (match typed_binding with
      | Some typed when not (same_sort typed.Expr_translate.sort binding.sort) ->
        Some (id.it, typed)
      | Some _ | None -> Some (id.it, binding))
    | Some _ -> None
    | None ->
      (match typed_binding with
      | Some binding -> Some (id.it, binding)
      | None -> None))
  | _ -> None

let binding_map_targets env ~bound_vars generators =
  generators
  |> List.filter_map (fun (target_generator, target_source_exp) ->
    match
      unbound_direct_var env ~bound_vars target_source_exp,
      flat_list_element_typ target_source_exp.note
    with
    | Some target_source_id, Some target_element_typ ->
      (match Expr_translate.carrier_sort_of_typ target_element_typ with
      | Some target_element_sort ->
        let source_binding =
          match Expr_translate.find_var env target_source_id.it with
          | Some binding -> Some (binding.term, binding)
          | None -> typed_var_for_exp target_source_id target_source_exp
        in
        (match source_binding with
        | Some (target_source_term, target_source_binding) ->
          Some
            { target_generator
            ; target_source_id
            ; target_source_exp
            ; target_source_term
            ; target_source_binding
            ; target_element_typ
            ; target_element_sort
            }
        | None -> None)
      | None -> None)
    | _ -> None)

let inverse_binding_unsupported ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-binding"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let lower_inverse_arg ctx env ~bound_vars origin exp =
  match unbound_env_var_binding env ~bound_vars exp with
  | Some (id, binding) ->
    if Condition_closure.is_match_pattern binding.term then
      Ok (Inverse_target (id, binding), binding.term, [], [])
    else
      Error
        [ inverse_binding_unsupported
            ctx origin exp
            ("unbound inverse target `" ^ id
             ^ "` is not represented by a Maude match pattern")
            "Keep this equality Unsupported until the target can be bound by a matching condition"
        ]
  | None ->
    (match unbound_direct_var env ~bound_vars exp with
    | Some id ->
    (match typed_var_for_exp id exp with
    | Some (term, binding) -> Ok (Inverse_target (id.it, binding), term, [], [])
    | None ->
      Error
        [ inverse_binding_unsupported
            ctx origin exp
            ("unbound inverse target `" ^ id.it
             ^ "` has no known Maude carrier sort")
            "Keep this equality Unsupported until the target type has a carrier-preserving encoding"
        ])
    | None ->
    let result = lower_with_source_carrier ctx env origin exp in
    (match result.term with
    | Some term -> Ok (Inverse_known term, term, result.guards, result.diagnostics)
    | None -> Error result.diagnostics))

let collect_inverse_args ctx env ~bound_vars origin exps =
  let step acc item =
    match acc with
    | Error diagnostics -> Error diagnostics
    | Ok (items, terms, guards, diagnostics, targets) ->
      (match lower_inverse_arg ctx env ~bound_vars origin item with
      | Error new_diagnostics -> Error (diagnostics @ new_diagnostics)
      | Ok (arg, term, new_guards, new_diagnostics) ->
        let targets =
          match arg with
          | Inverse_known _ -> targets
          | Inverse_target (id, binding) -> (id, binding) :: targets
        in
        Ok
          ( items @ [ arg ]
          , terms @ [ term ]
          , guards @ new_guards
          , diagnostics @ new_diagnostics
          , targets ))
  in
  List.fold_left step (Ok ([], [], [], [], [])) exps

let inverse_known_terms args =
  args
  |> List.filter_map (function
    | Inverse_known term -> Some term
    | Inverse_target _ -> None)

let inverse_target args =
  args
  |> List.filter_map (function
    | Inverse_known _ -> None
    | Inverse_target (id, binding) -> Some (id, binding))

let inverse_original_terms args =
  args
  |> List.map (function
    | Inverse_known term -> term
    | Inverse_target (_id, binding) -> binding.Expr_translate.term)

let var_exp_id exp =
  match exp.it with
  | VarE id -> Some id
  | _ -> None

let exp_is_var id exp =
  match var_exp_id exp with
  | Some actual -> actual.it = id.it
  | None -> false

let pair_list_body left_id right_id body =
  match body.it with
  | ListE [ left; right ] when exp_is_var left_id left && exp_is_var right_id right ->
    true
  | _ -> false

let pair_split_target env ~bound_vars source_exp =
  match unbound_direct_var env ~bound_vars source_exp with
  | None -> None
  | Some id ->
    (match typed_var_for_exp id source_exp with
    | Some (_term, binding)
      when sort_name binding.Expr_translate.sort = "SpectecTerminals" ->
      Some (id.it, binding)
    | Some _ | None -> None)

let pair_split_unsupported ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-pair-split"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let inverse_pair_split_shape runtime_exp =
  match runtime_exp.it with
  | IterE (body, (List, [ left_id, left_source; right_id, right_source ]))
    when pair_list_body left_id right_id body ->
    Some (body, left_id, left_source, right_id, right_source)
  | _ -> None

let lower_inverse_pair_split_eq_premise
    ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (id, args) ->
    let graph = Context.function_graph ctx in
    let target_id = call_target_id ctx id in
    (match
       Analysis.Function_graph.find_definition graph target_id.it,
       Analysis.Function_graph.definition_inverse graph target_id.it
     with
    | Some _, Some _ ->
      let runtime_exps =
        args
        |> List.filter_map (fun arg ->
          match arg.it with
          | ExpA exp -> Some exp
          | TypA _ | DefA _ | GramA _ -> None)
      in
      (match runtime_exps with
      | [ runtime_exp ] ->
        (match inverse_pair_split_shape runtime_exp with
        | None -> None
        | Some (body, left_id, left_source, right_id, right_source) ->
          (match
             pair_split_target env ~bound_vars left_source,
             pair_split_target env ~bound_vars right_source
           with
          | Some (left_source_id, left_binding),
            Some (right_source_id, right_binding) ->
            let known_result = lower_with_source_carrier ctx env origin known_exp in
            (match known_result.term with
            | None ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics = known_result.diagnostics
                }
            | Some known_term ->
              let stem =
                Naming.helper_local_var_stem origin
                ^ "_"
                ^ Naming.maude_var "pair-split"
              in
              let split_request =
                { Helper.kind =
                    Helper.Inverse_pair_split
                      { source = source_echo_exp exp
                      ; left_source_id
                      ; right_source_id
                      ; pair_source = source_echo_exp body
                      ; left_head_var =
                          Naming.maude_var (stem ^ "-" ^ left_id.it ^ "-left")
                      ; right_head_var =
                          Naming.maude_var (stem ^ "-" ^ right_id.it ^ "-right")
                      ; left_stream_var =
                          Naming.maude_var (stem ^ "-" ^ left_id.it ^ "-stream")
                      ; right_stream_var =
                          Naming.maude_var (stem ^ "-" ^ right_id.it ^ "-stream")
                      ; source_tail_var = Naming.maude_var (stem ^ "-tail")
                      }
                ; reason =
                    "inverse pair-split for an inverse-hinted definition over a source pair IterE"
                ; origin
                }
              in
              let helper_name = Helper.request (Context.helpers ctx) split_request in
              let split_pattern =
                app
                  (Helper.pair_split_result_op helper_name)
                  [ left_binding.term; right_binding.term ]
              in
              let split_subject =
                app (Helper.pair_split_unzip_op helper_name) [ known_term ]
              in
              let env_after =
                Expr_translate.add_var env left_source_id left_binding
              in
              let env_after =
                Expr_translate.add_var env_after right_source_id right_binding
              in
              let original_result =
                lower_with_source_carrier ctx env_after origin call_exp
              in
              (match original_result.term with
              | Some original_term ->
                let conditions =
                  known_result.guards
                  @ [ MatchCond (split_pattern, split_subject) ]
                  @ original_result.guards
                  @ [ EqCond (original_term, known_term) ]
                in
                Some
                  (with_conditions
                     env_after
                     bound_vars
                     conditions
                     (known_result.diagnostics @ original_result.diagnostics))
              | None ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      known_result.diagnostics @ original_result.diagnostics
                  }))
          | _ ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  [ pair_split_unsupported
                      ctx
                      origin
                      exp
                      "inverse pair-split requires both pair generator source lists to be unbound sequence variables"
                      "Keep this equality Unsupported until non-variable or already-bound pair sources have a source-preserving inverse model"
                  ]
              }))
      | [] | _ :: _ :: _ -> None)
    | _ -> None)
  | _ -> None

let concatn_chunks_unsupported ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-concatn-chunks"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let concatn_chunks_unsupported_source ctx origin source_echo reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-concatn-chunks"
    ~source_echo
    ~reason
    ~suggestion
    ()

let concatn_runtime_args args =
  args
  |> List.filter_map (fun arg ->
    match arg.it with
    | ExpA exp -> Some exp
    | TypA _ | DefA _ | GramA _ -> None)

let concatn_chunks_target env ~bound_vars source_exp =
  match unbound_direct_var env ~bound_vars source_exp with
  | None -> None
  | Some id ->
    (match typed_var_for_exp id source_exp with
    | Some (_term, binding)
      when sort_name binding.Expr_translate.sort = "SpectecTerminals" ->
      Some (id.it, binding)
    | Some _ | None ->
      (match source_exp.note.it with
      | IterT (_, ListN _) ->
        let sort = sort "SpectecTerminals" in
        let term = Var (Naming.maude_var id.it ^ ":" ^ sort_name sort) in
        Some (id.it, { Expr_translate.term; sort; typ = source_exp.note })
      | _ -> None))

type concatn_bytes_arg =
  | Bytes_target
  | Bytes_capture of Helper.capture

let concatn_bytes_arg_formal target_head_var = function
  | Bytes_target -> Var target_head_var
  | Bytes_capture capture -> Var capture.Helper.formal_var

let lower_concatn_bytes_args
    ctx env origin stem generator_id args =
  let rec loop index target_seen roles guards diagnostics = function
    | [] ->
      if target_seen then
        Ok (List.rev roles, List.rev guards, List.rev diagnostics)
      else
        Error
          [ concatn_chunks_unsupported_source
              ctx
              origin
              ("generator " ^ generator_id.it)
              "inner bytes function does not use the ListN generator variable as an inverse target"
              "Keep this equality Unsupported until the body function exposes exactly one element-wise target variable"
          ]
    | arg :: rest ->
      (match arg.it with
      | ExpA arg_exp when exp_is_var generator_id arg_exp && not target_seen ->
        loop
          (index + 1)
          true
          (Bytes_target :: roles)
          guards
          diagnostics
          rest
      | ExpA arg_exp when exp_is_var generator_id arg_exp ->
        Error
          [ concatn_chunks_unsupported
              ctx
              origin
              arg_exp
              "inner bytes function uses the ListN generator variable more than once"
              "Keep this equality Unsupported until the inverse target is linear in the bytes function call"
          ]
      | ExpA arg_exp ->
        let result = lower_with_source_carrier ctx env origin arg_exp in
        (match result.term, Expr_translate.carrier_sort_of_typ arg_exp.note with
        | Some term, Some sort ->
          let capture =
            { Helper.source_id = source_echo_exp arg_exp
            ; call_term = term
            ; formal_var =
                Naming.maude_var (stem ^ "-cap-" ^ string_of_int index)
            ; sort
            ; typ = arg_exp.note
            }
          in
          loop
            (index + 1)
            target_seen
            (Bytes_capture capture :: roles)
            (List.rev_append result.guards guards)
            (List.rev_append result.diagnostics diagnostics)
            rest
        | None, _ | _, None ->
          Error
            (result.diagnostics
             @ [ concatn_chunks_unsupported
                   ctx
                   origin
                   arg_exp
                   "known argument to the inner bytes function could not lower to a Maude carrier term"
                   "Bind the bytes function arguments through earlier premises before using fixed-width concatn inverse"
               ]))
      | TypA _ | DefA _ | GramA _ ->
        Error
          [ concatn_chunks_unsupported_source
              ctx
              origin
              (Il.Print.string_of_arg arg)
              "inner bytes function has a static argument, which is outside this fixed-width concatn inverse slice"
              "Keep this equality Unsupported until static bytes-function arguments are represented in the helper key"
          ])
  in
  loop 0 false [] [] [] args

let concatn_chunks_shape runtime_exp =
  match runtime_exp.it with
  | IterE (body, (ListN (count_exp, None), [ generator_id, source_exp ])) ->
    (match body.it with
    | CallE (bytes_id, bytes_args) ->
      Some (body, bytes_id, bytes_args, count_exp, generator_id, source_exp)
    | _ -> None)
  | _ -> None

let lower_inverse_concatn_chunks_eq_premise
    ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (concatn_id, concatn_args) ->
    let graph = Context.function_graph ctx in
    let concatn_target = call_target_id ctx concatn_id in
    (match
       Analysis.Function_graph.find_definition graph concatn_target.it,
       Analysis.Function_graph.definition_inverse graph concatn_target.it
     with
    | Some _, Some _ ->
      (match concatn_runtime_args concatn_args with
      | [ runtime_exp; width_exp ] ->
        (match concatn_chunks_shape runtime_exp with
        | None -> None
        | Some (_body, bytes_id, bytes_args, count_exp, generator_id, source_exp) ->
          let bytes_target = call_target_id ctx bytes_id in
          (match
             Analysis.Function_graph.find_definition graph bytes_target.it,
             Analysis.Function_graph.definition_inverse graph bytes_target.it,
             concatn_chunks_target env ~bound_vars source_exp
           with
          | Some _, Some inverse_id, Some (target_source_id, target_binding) ->
            let stem =
              Naming.helper_local_var_stem origin
              ^ "_"
              ^ Naming.maude_var "concatn-chunks"
            in
            let target_head_var =
              Naming.maude_var (stem ^ "-" ^ generator_id.it ^ "-head")
            in
            (match
               lower_concatn_bytes_args
                 ctx
                 env
                 origin
                 stem
                 generator_id
                 bytes_args
             with
            | Error diagnostics ->
              Some { (empty_with_env ~bound_vars env) with diagnostics }
            | Ok (arg_roles, arg_guards, arg_diagnostics) ->
              let known_result = lower_with_source_carrier ctx env origin known_exp in
              let count_result =
                Expr_translate.lower_numeric_guard_value ctx env origin count_exp
              in
              let width_result =
                Expr_translate.lower_numeric_guard_value ctx env origin width_exp
              in
              (match known_result.term, count_result.term, width_result.term with
              | Some known_term, Some count_term, Some width_term ->
                let captures =
                  arg_roles
                  |> List.filter_map (function
                    | Bytes_target -> None
                    | Bytes_capture capture -> Some capture)
                in
                let capture_terms =
                  captures |> List.map (fun capture -> capture.Helper.call_term)
                in
                let bytes_call_formals =
                  arg_roles
                  |> List.map (concatn_bytes_arg_formal target_head_var)
                in
                let inverse_call_formals =
                  (captures
                   |> List.map (fun capture -> Var capture.Helper.formal_var))
                  @ [ Var (Naming.maude_var (stem ^ "-chunk")) ]
                in
                let helper_request =
                  { Helper.kind =
                      Helper.Inverse_concatn_chunks
                        { source = source_echo_exp exp
                        ; target_source_id
                        ; bytes_op = Naming.definition_op bytes_target
                        ; inverse_op =
                            Naming.definition_op { bytes_id with it = inverse_id }
                        ; captures
                        ; bytes_call_formals
                        ; inverse_call_formals
                        ; target_head_var
                        ; target_stream_var =
                            Naming.maude_var (stem ^ "-" ^ target_source_id ^ "-stream")
                        ; bytes_var = Naming.maude_var (stem ^ "-bytes")
                        ; bytes_head_var = Naming.maude_var (stem ^ "-byte-head")
                        ; bytes_tail_var = Naming.maude_var (stem ^ "-byte-tail")
                        ; width_var = Naming.maude_var (stem ^ "-width")
                        ; count_tail_var = Naming.maude_var (stem ^ "-count-tail")
                        ; chunk_var = Naming.maude_var (stem ^ "-chunk")
                        }
                  ; reason =
                      "fixed-width concatn inverse over an inverse-hinted element bytes function"
                  ; origin
                  }
                in
                let helper_name =
                  Helper.request (Context.helpers ctx) helper_request
                in
                let inverse_subject =
                  app
                    (Helper.concatn_chunks_inverse_op helper_name)
                    (capture_terms @ [ known_term; width_term; count_term ])
                in
                let inverse_pattern =
                  app
                    (Helper.concatn_chunks_result_op helper_name)
                    [ target_binding.term ]
                in
                let prefix_conditions =
                  arg_guards @ known_result.guards @ width_result.guards
                  @ count_result.guards
                in
                let prefix_bound =
                  conditions_bound_vars bound_vars prefix_conditions
                in
                let inverse_args_bound =
                  Condition_closure.term_vars inverse_subject
                  |> List.for_all (fun var -> List.mem var prefix_bound)
                in
                if not inverse_args_bound then
                  Some
                    { (empty_with_env ~bound_vars env) with
                      diagnostics =
                        arg_diagnostics @ known_result.diagnostics
                        @ width_result.diagnostics @ count_result.diagnostics
                        @ [ concatn_chunks_unsupported
                              ctx
                              origin
                              exp
                              "fixed-width concatn inverse uses count, width, bytes, or capture variables that are not bound before the matching condition"
                              "Bind those inputs through earlier premises before emitting this helper MatchCond"
                          ]
                    }
                else
                  let env_after =
                    Expr_translate.add_var env target_source_id target_binding
                  in
                  let original_result =
                    lower_with_source_carrier ctx env_after origin call_exp
                  in
                  (match original_result.term with
                  | Some original_term ->
                    let conditions =
                      prefix_conditions
                      @ [ MatchCond (inverse_pattern, inverse_subject) ]
                      @ original_result.guards
                      @ [ EqCond (original_term, known_term) ]
                    in
                    Some
                      (with_conditions
                         env_after
                         bound_vars
                         conditions
                         (arg_diagnostics @ known_result.diagnostics
                          @ width_result.diagnostics @ count_result.diagnostics
                          @ original_result.diagnostics))
                  | None ->
                    Some
                      { (empty_with_env ~bound_vars env_after) with
                        diagnostics =
                          arg_diagnostics @ known_result.diagnostics
                          @ width_result.diagnostics @ count_result.diagnostics
                          @ original_result.diagnostics
                      })
              | _ ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      arg_diagnostics @ known_result.diagnostics
                      @ width_result.diagnostics @ count_result.diagnostics
                      @ [ concatn_chunks_unsupported
                            ctx
                            origin
                            exp
                            "fixed-width concatn inverse could not lower bytes, count, or width to Maude terms"
                            "Keep this equality Unsupported until bytes, count, and width are admissible before the inverse binding"
                        ]
                  }))
          | _ ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  [ concatn_chunks_unsupported
                      ctx
                      origin
                      exp
                      "fixed-width concatn inverse requires an unbound sequence target and an inverse-hinted element bytes function"
                      "Do not lower arbitrary concatn inverse search without source inverse metadata for the element function"
                  ]
              }))
      | [] | [ _ ] | _ :: _ :: _ :: _ -> None)
    | _ -> None)
  | _ -> None

let lower_inverse_binding_eq_premise ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (id, args) ->
    let graph = Context.function_graph ctx in
    let target_id = call_target_id ctx id in
    (match
       Analysis.Function_graph.find_definition graph target_id.it,
       Analysis.Function_graph.definition_inverse graph target_id.it
     with
    | Some definition, Some inverse_id
      when definition_has_only_runtime_params definition
           && List.length definition.params = List.length args ->
      let runtime_exps =
        args
        |> List.filter_map (fun arg ->
          match arg.it with
          | ExpA exp -> Some exp
          | TypA _ | DefA _ | GramA _ -> None)
      in
      if List.length runtime_exps <> List.length args then
        None
      else
        (match collect_inverse_args ctx env ~bound_vars origin runtime_exps with
        | Error diagnostics ->
          Some { (empty_with_env ~bound_vars env) with diagnostics }
        | Ok (arg_items, _arg_terms, arg_guards, arg_diagnostics, _targets) ->
          (match inverse_target arg_items with
          | [ (target_id_text, target_binding) ] ->
            let known_result = lower_with_source_carrier ctx env origin known_exp in
            (match known_result.term with
            | None ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics = arg_diagnostics @ known_result.diagnostics
                }
            | Some known_term ->
              let inverse_id_phrase = { id with it = inverse_id } in
              let inverse_call =
                app
                  (Naming.definition_op inverse_id_phrase)
                  (inverse_known_terms arg_items @ [ known_term ])
              in
              let original_call =
                app
                  (Naming.definition_op target_id)
                  (inverse_original_terms arg_items)
              in
              let prefix_conditions = arg_guards @ known_result.guards in
              let prefix_bound =
                conditions_bound_vars bound_vars prefix_conditions
              in
              let inverse_args_bound =
                Condition_closure.term_vars inverse_call
                |> List.for_all (fun var -> List.mem var prefix_bound)
              in
              if not inverse_args_bound then
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      arg_diagnostics @ known_result.diagnostics
                      @ [ inverse_binding_unsupported
                            ctx origin exp
                            "inverse binding call uses variables that are not bound by the lhs or earlier equality guards"
                            "Bind the inverse call arguments through earlier source premises before emitting this matching condition"
                        ]
                  }
              else
                let conditions =
                  prefix_conditions
                  @ [ MatchCond (target_binding.term, inverse_call)
                    ; EqCond (original_call, known_term)
                    ]
                in
                let env_after =
                  Expr_translate.add_var env target_id_text target_binding
                in
                Some
                  (with_conditions
                     env_after
                     bound_vars
                     conditions
                     (arg_diagnostics @ known_result.diagnostics)))
          | [] | _ :: _ :: _ -> None))
    | _ -> None)
  | _ -> None

let numeric_inverse_unsupported ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/numeric-inverse-binding"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let target_numeric_var env ~bound_vars exp =
  match unbound_direct_var env ~bound_vars exp with
  | None -> None
  | Some id ->
    (match typed_var_for_exp id exp with
    | Some (_term, binding)
      when List.mem (sort_name binding.Expr_translate.sort) [ "Nat"; "Int" ] ->
      Some (id.it, binding)
    | Some _ | None -> None)

let multiplication_inverse_target ctx env ~bound_vars origin product_exp =
  let lower_factor exp =
    Expr_translate.lower_numeric_guard_value ctx env origin exp
  in
  let candidate target_exp factor_exp product =
    match target_numeric_var env ~bound_vars target_exp with
    | None -> None
    | Some (id, binding) ->
      let factor = lower_factor factor_exp in
      Some (id, binding, factor, product)
  in
  match product_exp.it with
  | BinE (`MulOp, _, left, right) ->
    (match candidate left right (fun target factor -> app "_*_" [ target; factor ]) with
    | Some _ as result -> result
    | None -> candidate right left (fun target factor -> app "_*_" [ factor; target ]))
  | _ -> None

let lower_numeric_inverse_binding_eq_premise
    ctx env ~bound_vars origin exp product_exp known_exp =
  match multiplication_inverse_target ctx env ~bound_vars origin product_exp with
  | None -> None
  | Some (target_id, target_binding, factor_result, product_term) ->
    let known_result =
      Expr_translate.lower_numeric_guard_value ctx env origin known_exp
    in
    (match factor_result.term, known_result.term with
    | Some factor_term, Some known_term ->
      let prefix_conditions = factor_result.guards @ known_result.guards in
      (match
         Condition_closure.conditions_admissible_bound
           bound_vars
           prefix_conditions
       with
      | None ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              factor_result.diagnostics @ known_result.diagnostics
              @ [ numeric_inverse_unsupported
                    ctx
                    origin
                    exp
                    "numeric inverse binding arguments are not admissible from the lhs or earlier premise conditions"
                    "Bind the multiplication factor and known value before solving the numeric target variable"
                ]
          }
      | Some bound_after_prefix ->
        let needed =
          Condition_closure.term_vars factor_term
          @ Condition_closure.term_vars known_term
          |> List.sort_uniq String.compare
        in
        if not (vars_subset needed bound_after_prefix) then
          Some
            { (empty_with_env ~bound_vars env) with
              diagnostics =
                factor_result.diagnostics @ known_result.diagnostics
                @ [ numeric_inverse_unsupported
                      ctx
                      origin
                      exp
                      "numeric inverse binding would use a factor or known value before it is bound"
                      "Keep this equality Unsupported until the source provides earlier binding conditions"
                  ]
            }
        else
          let quotient = app "_quo_" [ known_term; factor_term ] in
          let conditions =
            prefix_conditions
            @ [ BoolCond (app "_=/=_" [ factor_term; Const "0" ])
              ; MatchCond (target_binding.term, quotient)
              ; EqCond (product_term target_binding.term factor_term, known_term)
              ]
          in
          let env_after =
            Expr_translate.add_var env target_id target_binding
          in
          Some
            (with_conditions
               env_after
               bound_vars
               conditions
               (factor_result.diagnostics @ known_result.diagnostics)))
    | _ ->
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            factor_result.diagnostics @ known_result.diagnostics
            @ [ numeric_inverse_unsupported
                  ctx
                  origin
                  exp
                  "numeric inverse binding could not lower the multiplication factor or known side as a numeric guard term"
                  "Keep this equality Unsupported until both sides have numeric Maude carrier terms"
              ]
        })

let first_success attempts =
  attempts |> List.find_map (fun attempt -> attempt ())

let try_category_membership_eq ctx env ~bound_vars origin left right () =
  lower_category_membership_eq_premise ctx env ~bound_vars origin left right

let try_inverse_binding_eq ctx env ~bound_vars origin exp left right () =
  lower_inverse_binding_eq_premise ctx env ~bound_vars origin exp left right

let try_inverse_pair_split_eq ctx env ~bound_vars origin exp left right () =
  lower_inverse_pair_split_eq_premise ctx env ~bound_vars origin exp left right

let try_inverse_concatn_chunks_eq ctx env ~bound_vars origin exp left right () =
  lower_inverse_concatn_chunks_eq_premise ctx env ~bound_vars origin exp left right

let try_numeric_inverse_binding_eq ctx env ~bound_vars origin exp left right () =
  lower_numeric_inverse_binding_eq_premise ctx env ~bound_vars origin exp left right

let lower_projection_binding_value ctx env origin exp =
  let numeric_result =
    Expr_translate.lower_numeric_guard_value ctx env origin exp
  in
  if numeric_result.term <> None && not (result_has_fatal numeric_result) then
    numeric_result
  else
    Expr_translate.lower_value ctx env origin exp

let inverse_numeric_conversion_exp value_exp source_numtyp target_numtyp =
  { value_exp with
    it = CvtE (value_exp, target_numtyp, source_numtyp)
  ; note = { value_exp.note with it = NumT source_numtyp }
  }

let projection_binding_sides projection_exp value_exp =
  match projection_exp.it with
  | CvtE (inner_projection, source_numtyp, target_numtyp) ->
    ( inner_projection
    , inverse_numeric_conversion_exp value_exp source_numtyp target_numtyp )
  | _ -> projection_exp, value_exp

let lower_unary_projection_binding_eq_premise
    ctx env ~bound_vars origin _exp projection_exp value_exp =
  let projection_exp, value_exp =
    projection_binding_sides projection_exp value_exp
  in
  match projection_exp.it with
  | ProjE (({ it = UncaseE (scrutinee_exp, _mixop); _ } as _uncase_exp), 0) ->
    (match scrutinee_exp.it with
    | VarE scrutinee_id ->
      (match Expr_translate.find_var env scrutinee_id.it with
      | Some scrutinee_binding when not (binding_is_bound bound_vars scrutinee_binding) ->
        (match lower_projection_binding_value ctx env origin projection_exp with
        | { term = Some (App (projection_op, [ scrutinee_term ])); guards = projection_guards; diagnostics = projection_diagnostics } ->
          (match
             Constructor_registry.lookup_unary_projection
               (Context.constructors ctx)
               ~projection_op
           with
          | Constructor_registry.Projection_found entry ->
            let value_result =
              lower_projection_binding_value ctx env origin value_exp
            in
            (match value_result.term with
            | Some value_term ->
              let prefix_conditions = value_result.guards in
              (match
                 Condition_closure.conditions_admissible_bound
                   bound_vars
                   prefix_conditions
               with
              | None -> None
              | Some bound_after_prefix ->
                if
                  vars_subset
                    (Condition_closure.term_vars value_term)
                    bound_after_prefix
                then (
                  let match_condition =
                    MatchCond
                      ( scrutinee_term
                      , app entry.Constructor_registry.constructor_op [ value_term ] )
                  in
                  let conditions =
                    prefix_conditions @ [ match_condition ] @ projection_guards
                  in
                  let env_after =
                    Expr_translate.add_var
                      env
                      scrutinee_id.it
                      scrutinee_binding
                  in
                  Some
                    (with_conditions
                       env_after
                       bound_vars
                       conditions
                       (projection_diagnostics @ value_result.diagnostics)))
                else
                  None)
            | None -> None)
          | Constructor_registry.Projection_missing
          | Constructor_registry.Projection_ambiguous _ -> None)
        | _ -> None)
      | Some _ | None -> None)
    | _ -> None)
  | _ -> None

let try_unary_projection_binding_eq ctx env ~bound_vars origin exp left right () =
  lower_unary_projection_binding_eq_premise ctx env ~bound_vars origin exp left right

let is_raw_numeric_sort sort =
  match sort_name sort with
  | "Nat" | "Int" | "Rat" -> true
  | _ -> false

let direct_binding_sides target_exp value_exp =
  projection_binding_sides target_exp value_exp

let lower_direct_binding_value ctx env origin target_binding value_exp =
  let value_result = Expr_translate.lower_value ctx env origin value_exp in
  match value_result.term with
  | Some _ -> value_result
  | None when is_raw_numeric_sort target_binding.Expr_translate.sort ->
    let numeric_result =
      Expr_translate.lower_numeric_guard_value ctx env origin value_exp
    in
    (match numeric_result.term with
    | Some _ -> numeric_result
    | None -> value_result)
  | None -> value_result

let lower_direct_var_binding_eq_premise ctx env ~bound_vars origin _exp target_exp value_exp =
  let target_exp, value_exp =
    direct_binding_sides target_exp value_exp
  in
  match unbound_var_binding env ~bound_vars target_exp with
  | None -> None
  | Some (target_id, target_binding) ->
    if not (Condition_closure.is_match_pattern target_binding.term) then
      None
    else
      let value_result =
        lower_direct_binding_value ctx env origin target_binding value_exp
      in
      (match value_result.term with
      | Some value_term ->
        let prefix_bound =
          conditions_bound_vars bound_vars value_result.guards
        in
        if vars_subset (Condition_closure.term_vars value_term) prefix_bound then
          let env_after =
            Expr_translate.add_var env target_id target_binding
          in
          Some
            (with_conditions
               env_after
               bound_vars
               (value_result.guards @ [ MatchCond (target_binding.term, value_term) ])
               value_result.diagnostics)
        else
          None
      | None -> None)

let try_direct_var_binding_eq ctx env ~bound_vars origin exp left right () =
  lower_direct_var_binding_eq_premise ctx env ~bound_vars origin exp left right

let lower_optional_map_inverse_eq_premise
    ctx env ~bound_vars origin exp known_exp mapped_exp =
  let optional_iter =
    match mapped_exp.it with
    | IterE (body, (Opt, [ generator_id, source_exp ])) ->
      (match
         unbound_var_binding env ~bound_vars source_exp,
         flat_optional_element_typ source_exp.note,
         flat_optional_element_typ known_exp.note
       with
      | Some (source_id, source_binding), Some source_element_typ, Some _ ->
        (match Expr_translate.carrier_sort_of_typ source_element_typ with
        | Some source_element_sort ->
          Some
            ( body
            , generator_id
            , source_exp
            , source_id
            , source_binding
            , source_element_typ
            , source_element_sort )
        | None -> None)
      | _ -> None)
    | _ -> None
  in
  match optional_iter with
  | None -> None
  | Some
      ( body
      , generator_id
      , source_exp
      , source_id
      , source_binding
      , source_element_typ
      , source_element_sort ) ->
    let source_result = Expr_translate.lower_sequence ctx env origin known_exp in
    (match source_result.term with
    | None -> None
    | Some source_term ->
      let source_bound =
        conditions_bound_vars bound_vars source_result.guards
      in
      if
        (not
           (vars_subset
              (Condition_closure.term_vars source_term)
              source_bound))
        || diagnostics_have_fatal source_result.diagnostics
      then
        None
      else
        let stem = helper_local_stem origin (source_echo_exp exp) in
        let helper_head_var = "HEAD" ^ stem in
        let generator_binding =
          { Expr_translate.term = Var helper_head_var
          ; sort = source_element_sort
          ; typ = source_element_typ
          }
        in
        let body_source_ids =
          source_and_note_free_var_ids body
          |> List.filter (fun id -> id <> generator_id.it)
          |> List.sort_uniq String.compare
        in
        let captures =
          body_source_ids
          |> capture_candidates env
          |> make_captures stem
        in
        let lower_body captures =
          let helper_env =
            Expr_translate.add_var
              (capture_env captures)
              generator_id.it
              generator_binding
          in
          Expr_translate.lower_value ctx helper_env origin body
        in
        let body_result = lower_body captures in
        (match body_result.term with
        | None -> None
        | Some body_term ->
          let body_used_vars =
            Condition_closure.external_vars_of_term_after_conditions
              [ helper_head_var ]
              body_term
              body_result.guards
          in
          let captures = captures |> filter_used_captures body_used_vars in
          let body_result = lower_body captures in
          (match body_result.term with
          | None -> None
          | Some body_term ->
            let allowed_vars = helper_head_var :: capture_vars captures in
            let body_external =
              Condition_closure.external_vars_of_term_after_conditions
                allowed_vars
                body_term
                body_result.guards
            in
            let helper_bound_after =
              Condition_closure.conditions_admissible_bound
                allowed_vars
                body_result.guards
            in
            if
              diagnostics_have_fatal body_result.diagnostics
              || body_external <> []
              || helper_bound_after = None
              || not (List.mem helper_head_var (Condition_closure.term_vars body_term))
              || not (Condition_closure.is_match_pattern body_term)
            then
              None
            else
              let helper_request =
                { Helper.kind =
                    Helper.Optional_map_inverse
                      { source_shape =
                          { iter_source = source_echo_exp mapped_exp
                          ; body_source = source_echo_exp body
                          ; source_source = source_echo_exp source_exp
                          ; output_typ_source =
                              Il.Print.string_of_typ known_exp.note
                          ; source_typ_source =
                              Il.Print.string_of_typ source_exp.note
                          }
                      ; generator_var = generator_id.it
                      ; helper_head_var
                      ; source_element_sort
                      ; captures
                      ; lowered_body = body_term
                      ; body_eq_conditions = body_result.guards
                      }
                ; reason = "optional IterE inverse binding helper"
                ; origin
                }
              in
              let helper_name =
                Helper.request (Context.helpers ctx) helper_request
              in
              let helper_call =
                app helper_name
                  (source_term
                   :: List.map (fun capture -> capture.Helper.call_term) captures)
              in
              let caller_conditions =
                source_result.guards
                @ [ BoolCond (is_opt source_term)
                  ; MatchCond (source_binding.Expr_translate.term, helper_call)
                  ]
              in
              if
                Condition_closure.external_vars_of_conditions
                  bound_vars
                  caller_conditions
                <> []
              then
                None
              else
                let result =
                  with_conditions
                    env
                    bound_vars
                    caller_conditions
                    (source_result.diagnostics @ body_result.diagnostics)
                in
                Some
                  { result with
                    env_after =
                      Expr_translate.add_var
                        result.env_after
                        source_id
                        source_binding
                  })))

let try_optional_map_inverse_eq ctx env ~bound_vars origin exp left right () =
  lower_optional_map_inverse_eq_premise ctx env ~bound_vars origin exp left right

let try_record_eq_match env ~bound_vars left right left_value right_value left_pattern right_pattern () =
  let record_match =
    match left.it, right.it with
    | _, StrE _ ->
      try_record_match_condition ~bound:bound_vars right_pattern left_value
    | StrE _, _ ->
      try_record_match_condition ~bound:bound_vars left_pattern right_value
    | _ -> None
  in
  match record_match with
  | Some (conditions, diagnostics) ->
    let env_after =
      match left.it, right.it with
      | _, StrE _ -> add_introduced_bindings env right_pattern.introduced_bindings
      | StrE _, _ -> add_introduced_bindings env left_pattern.introduced_bindings
      | _ -> env
    in
    Some (with_conditions env_after bound_vars conditions diagnostics)
  | None -> None

let try_pattern_eq_match env ~bound_vars pattern_result value_result () =
  match try_match_condition ~bound:bound_vars pattern_result value_result with
  | Some (conditions, diagnostics) ->
    let env_after =
      add_introduced_bindings env pattern_result.introduced_bindings
    in
    Some (with_conditions env_after bound_vars conditions diagnostics)
  | None -> None

let try_plain_eq ctx env ~bound_vars left_value right_value () =
  match try_eq_condition left_value right_value with
  | Some (conditions, diagnostics) ->
    let conditions =
      invert_unbound_unary_projection_conditions ctx bound_vars conditions
    in
    Some (with_conditions env bound_vars conditions diagnostics)
  | None -> None

let lower_eq_premise ctx env ~bound_vars origin (exp : exp) (left : exp) (right : exp) =
  match
    first_success
      [ try_category_membership_eq ctx env ~bound_vars origin left right
      ; try_category_membership_eq ctx env ~bound_vars origin right left
      ; try_inverse_concatn_chunks_eq ctx env ~bound_vars origin exp left right
      ; try_inverse_concatn_chunks_eq ctx env ~bound_vars origin exp right left
      ; try_inverse_pair_split_eq ctx env ~bound_vars origin exp left right
      ; try_inverse_pair_split_eq ctx env ~bound_vars origin exp right left
      ; try_optional_map_inverse_eq ctx env ~bound_vars origin exp left right
      ; try_optional_map_inverse_eq ctx env ~bound_vars origin exp right left
      ; try_inverse_binding_eq ctx env ~bound_vars origin exp left right
      ; try_inverse_binding_eq ctx env ~bound_vars origin exp right left
      ; try_numeric_inverse_binding_eq ctx env ~bound_vars origin exp left right
      ; try_numeric_inverse_binding_eq ctx env ~bound_vars origin exp right left
      ; try_unary_projection_binding_eq ctx env ~bound_vars origin exp left right
      ; try_unary_projection_binding_eq ctx env ~bound_vars origin exp right left
      ; try_direct_var_binding_eq ctx env ~bound_vars origin exp left right
      ; try_direct_var_binding_eq ctx env ~bound_vars origin exp right left
      ]
  with
  | Some result -> result
  | None ->
    let left_value = Expr_translate.lower_value ctx env origin left in
    let right_value = Expr_translate.lower_value ctx env origin right in
    let left_pattern = Expr_translate.lower_pattern_with_bindings ctx env origin left in
    let right_pattern = Expr_translate.lower_pattern_with_bindings ctx env origin right in
    match
      first_success
        [ try_record_eq_match
            env
            ~bound_vars
            left
            right
            left_value
            right_value
            left_pattern
            right_pattern
        ; try_pattern_eq_match env ~bound_vars left_pattern right_value
        ; try_pattern_eq_match env ~bound_vars right_pattern left_value
        ; try_plain_eq ctx env ~bound_vars left_value right_value
        ]
    with
    | Some result -> result
    | None -> lower_bool_premise ctx env ~bound_vars origin exp

let binding_mem_left_unbound bound_vars (pattern_result : Expr_translate.pattern_result) =
  match pattern_result.pattern_term with
  | None -> false
  | Some term ->
    not (vars_subset (Condition_closure.term_vars term) bound_vars)

let lower_singleton_sequence_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    (left_pattern : Expr_translate.pattern_result)
    (right_result : Expr_translate.result)
    ~failure_reason
    ~failure_suggestion
  =
  let left_term_opt = left_pattern.pattern_term in
  let right_term_opt = right_result.term in
  match left_term_opt, right_term_opt with
  | Some left_term, Some right_term
    when (not (pattern_result_has_fatal left_pattern))
         && (not (result_has_fatal right_result)) ->
    let singleton_pattern = app "seq" [ left_term ] in
    let guard_bound = conditions_bound_vars bound_vars right_result.guards in
    if vars_subset (Condition_closure.term_vars right_term) guard_bound then
      let conditions =
        right_result.guards @ [ MatchCond (singleton_pattern, right_term) ]
        @ left_pattern.pattern_guards
      in
      let env_after =
        add_introduced_bindings env left_pattern.introduced_bindings
      in
      Some
        (with_conditions
           env_after
           bound_vars
           conditions
           (right_result.diagnostics @ left_pattern.pattern_diagnostics))
    else
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            right_result.diagnostics @ left_pattern.pattern_diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IfPr/MemE/binding"
                  ~source_echo:(source_echo_exp exp)
                  ~reason:
                    "binding membership computed source uses variables that are not bound before the matching condition"
                  ~suggestion:
                    "Bind the computed source arguments through earlier source premises before emitting the MatchCond"
                  ()
              ]
        }
  | _ ->
    Some
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          right_result.diagnostics @ left_pattern.pattern_diagnostics
          @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"Premise/IfPr/MemE/binding"
                ~source_echo:(source_echo_exp exp)
                ~reason:failure_reason
                ~suggestion:failure_suggestion
                ()
            ]
      }

let call_result_can_bind_singleton_sequence exp typ =
  match exp.it, flat_list_element_typ typ with
  | CallE _, Some _ -> true
  | _ -> false

let lower_direct_call_result_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    (left_pattern : Expr_translate.pattern_result)
    (right_result : Expr_translate.result)
  =
  match left_pattern.pattern_term, right_result.term with
  | Some left_term, Some right_term
    when (not (pattern_result_has_fatal left_pattern))
         && (not (result_has_fatal right_result)) ->
    let guard_bound = conditions_bound_vars bound_vars right_result.guards in
    if vars_subset (Condition_closure.term_vars right_term) guard_bound then
      let conditions =
        right_result.guards @ [ MatchCond (left_term, right_term) ]
        @ left_pattern.pattern_guards
      in
      let env_after =
        add_introduced_bindings env left_pattern.introduced_bindings
      in
      Some
        (with_conditions
           env_after
           bound_vars
           conditions
           (right_result.diagnostics @ left_pattern.pattern_diagnostics))
    else
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            right_result.diagnostics @ left_pattern.pattern_diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IfPr/MemE/binding"
                  ~source_echo:(source_echo_exp exp)
                  ~reason:
                    "binding membership call result uses variables that are not bound before the matching condition"
                  ~suggestion:
                    "Bind the call arguments through earlier source premises before emitting the MatchCond"
                  ()
              ]
        }
  | _ ->
    Some
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          right_result.diagnostics @ left_pattern.pattern_diagnostics
          @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"Premise/IfPr/MemE/binding"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  "binding membership over a call result could not lower the left pattern or right call source"
                ~suggestion:
                  "Keep this premise Unsupported until both sides have source-shaped Maude terms"
                ()
            ]
      }

let lower_flat_sequence_membership_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    (left_pattern : Expr_translate.pattern_result)
    right
  =
  match flat_list_element_typ right.note with
  | None -> None
  | Some element_typ ->
    (match Expr_translate.carrier_sort_of_typ element_typ with
    | None -> None
    | Some element_sort when sort_name element_sort = "SpectecTerminals" -> None
    | Some _ ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      (match left_pattern.pattern_term, right_result.term with
      | Some left_term, Some right_term
        when (not (pattern_result_has_fatal left_pattern))
             && (not (result_has_fatal right_result)) ->
        let guard_bound =
          conditions_bound_vars bound_vars right_result.guards
        in
        if vars_subset (Condition_closure.term_vars right_term) guard_bound then
          let stem = helper_local_stem origin (source_echo_exp exp) in
          let sequence_sort_name = sort_name (sort "SpectecTerminals") in
          let prefix =
            Var ("PREFIX" ^ stem ^ ":" ^ sequence_sort_name)
          in
          let suffix =
            Var ("SUFFIX" ^ stem ^ ":" ^ sequence_sort_name)
          in
          let membership_pattern =
            sequence_concat prefix (sequence_concat left_term suffix)
          in
          let conditions =
            right_result.guards
            @ [ MatchCond (membership_pattern, right_term) ]
            @ left_pattern.pattern_guards
          in
          let env_after =
            add_introduced_bindings env left_pattern.introduced_bindings
          in
          Some
            (with_conditions
               env_after
               bound_vars
               conditions
               (right_result.diagnostics @ left_pattern.pattern_diagnostics))
        else
          Some
            { (empty_with_env ~bound_vars env) with
              eq_conditions = right_result.guards
            ; diagnostics =
                right_result.diagnostics @ left_pattern.pattern_diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"Premise/IfPr/MemE/binding"
                      ~source_echo:(source_echo_exp exp)
                      ~reason:
                        "binding membership source sequence uses variables that are not bound before the matching condition"
                      ~suggestion:
                        "Bind the sequence source through earlier source premises before emitting the membership MatchCond"
                      ()
                  ]
            }
      | _ ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              right_result.diagnostics @ left_pattern.pattern_diagnostics
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/IfPr/MemE/binding"
                    ~source_echo:(source_echo_exp exp)
                    ~reason:
                      "binding membership over a flat sequence could not lower the left pattern or right sequence source"
                    ~suggestion:
                      "Keep this premise Unsupported until both sides have source-shaped Maude terms"
                    ()
                ]
          }))

let lower_binding_mem_premise ctx env ~bound_vars origin exp left right =
  let left_pattern =
    Expr_translate.lower_pattern_with_bindings ctx env origin left
  in
  if not (binding_mem_left_unbound bound_vars left_pattern) then
    None
  else
    match flat_optional_element_typ right.note with
    | Some _ ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      lower_singleton_sequence_binding
        ctx env ~bound_vars origin exp left_pattern right_result
        ~failure_reason:
          "binding membership over an optional source could not lower the left pattern or right optional source"
        ~failure_suggestion:
          "Keep this premise Unsupported until both sides have source-shaped Maude terms"
    | None ->
      if call_result_can_bind_singleton_sequence right right.note then
        let right_result = Expr_translate.lower_sequence ctx env origin right in
        lower_direct_call_result_binding
          ctx env ~bound_vars origin exp left_pattern right_result
      else
        (match
           lower_flat_sequence_membership_binding
             ctx
             env
             ~bound_vars
             origin
             exp
             left_pattern
             right
         with
        | Some result -> Some result
        | None ->
          Some
            { (empty_with_env ~bound_vars env) with
              diagnostics =
                left_pattern.pattern_diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"Premise/IfPr/MemE/binding"
                      ~source_echo:(source_echo_exp exp)
                      ~reason:
                        ("binding membership requires an optional singleton source or a flat sequence source whose elements have a terminal carrier; source note is `"
                         ^ Il.Print.string_of_typ right.note
                         ^ "`")
                      ~suggestion:
                        "Use a source-preserving membership-search helper before lowering binding membership over non-flat or nested lists"
                      ()
                  ]
            })

let rec lower_if_premise ctx env ~bound_vars origin (exp : exp) =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    let left_origin = origin_for_if_conjunct origin "and-left" left in
    let right_origin = origin_for_if_conjunct origin "and-right" right in
    let left_result = lower_if_premise ctx env ~bound_vars left_origin left in
    let right_result =
      lower_if_premise
        ctx
        left_result.env_after
        ~bound_vars:left_result.bound_vars_after
        right_origin
        right
    in
    append left_result right_result
  | CmpE (`EqOp, _, left, right) ->
    lower_eq_premise ctx env ~bound_vars origin exp left right
  | MemE (left, right) ->
    (match lower_binding_mem_premise ctx env ~bound_vars origin exp left right with
    | Some result -> result
    | None -> lower_bool_premise ctx env ~bound_vars origin exp)
  | _ -> lower_bool_premise ctx env ~bound_vars origin exp

let relation_call rel_id inputs =
  App (Naming.relation_op rel_id, inputs)

let relation_equational_view_call rel_id inputs =
  App (Naming.relation_equational_view_op rel_id, inputs)

let sequence_of_terms = function
  | [] -> Const "eps"
  | hd :: tl -> List.fold_left (fun acc term -> app "_ _" [ acc; term ]) hd tl

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let tuple_component_pattern component term =
  match Expr_translate.carrier_sort_of_typ component.Relation_shape.typ with
  | Some sort when is_sequence_sort sort -> Some (app "seq" [ term ]), []
  | Some _ -> Some term, []
  | None ->
    None,
    [ "could not determine the Maude carrier for output component type `"
      ^ Il.Print.string_of_typ component.Relation_shape.typ
      ^ "`"
    ]

let tuple_pattern_from_components components terms =
  let pairs = List.combine components terms in
  let patterns, errors =
    pairs
    |> List.map (fun (component, term) -> tuple_component_pattern component term)
    |> List.fold_left
         (fun (patterns, errors) (pattern, new_errors) ->
           (match pattern with
           | None -> patterns
           | Some pattern -> patterns @ [ pattern ]),
           errors @ new_errors)
         ([], [])
  in
  if errors <> [] then
    None, errors
  else
    Some (app "tuple" [ sequence_of_terms patterns ]), []

let deterministic_result_var origin rel_id sort =
  let seed =
    String.concat
      "-"
      [ "deterministic-result"
      ; rel_id.it
      ; Origin.source_location origin
      ; Origin.path origin
      ]
  in
  Var (Naming.maude_var ~fallback:"DET" seed ^ ":" ^ sort_name sort)

let equational_view_result_var origin rel_id sort =
  let seed =
    String.concat
      "-"
      [ "equational-view-result"
      ; rel_id.it
      ; Origin.source_location origin
      ; Origin.path origin
      ]
  in
  Var (Naming.maude_var ~fallback:"VIEW" seed ^ ":" ^ sort_name sort)

let lower_value_components ctx env origin exps =
  let results =
    exps |> List.map (Expr_translate.lower_value ctx env origin)
  in
  let terms =
    results
    |> List.filter_map (fun (result : Expr_translate.result) -> result.term)
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

let runtime_predicate_var_term ~bound_vars source_id sort =
  let raw_var = Naming.maude_var source_id in
  let typed_var = raw_var ^ ":" ^ sort_name sort in
  if List.mem typed_var bound_vars then
    Var typed_var
  else if List.mem raw_var bound_vars then
    Var raw_var
  else
    Var typed_var

let rec lower_runtime_predicate_value ctx env ~bound_vars origin exp =
  match exp.it with
  | VarE id when Expr_translate.find_var env id.it = None ->
    (match Expr_translate.carrier_sort_of_typ exp.note with
    | Some sort ->
      { Expr_translate.term =
          Some (runtime_predicate_var_term ~bound_vars id.it sort)
      ; guards = []
      ; diagnostics = []
      }
    | None -> Expr_translate.lower_value ctx env origin exp)
  | IdxE (base, index_exp) ->
    let base_result =
      lower_runtime_predicate_value
        ctx
        env
        ~bound_vars
        (Origin.with_child
           origin
           "idx-base"
           ~ast_constructor:"Expr/IdxE"
           base.at
           ~source_echo:(Il.Print.string_of_exp base))
        base
    in
    let index_result =
      lower_runtime_predicate_value
        ctx
        env
        ~bound_vars
        (Origin.with_child
           origin
           "idx-index"
           ~ast_constructor:"Expr/IdxE"
           index_exp.at
           ~source_echo:(Il.Print.string_of_exp index_exp))
        index_exp
    in
    (match base_result.term, index_result.term with
    | Some base_term, Some index_term ->
      { Expr_translate.term = Some (app "index" [ base_term; index_term ])
      ; guards = base_result.guards @ index_result.guards
      ; diagnostics = base_result.diagnostics @ index_result.diagnostics
      }
    | _ ->
      { Expr_translate.term = None
      ; guards = base_result.guards @ index_result.guards
      ; diagnostics = base_result.diagnostics @ index_result.diagnostics
      })
  | SubE (inner, _source_typ, _target_typ) ->
    lower_runtime_predicate_value ctx env ~bound_vars origin inner
  | CvtE (inner, _source_typ, _target_typ) ->
    lower_runtime_predicate_value ctx env ~bound_vars origin inner
  | _ -> Expr_translate.lower_value ctx env origin exp

let lower_runtime_predicate_value_components ctx env ~bound_vars origin exps =
  let results =
    exps |> List.map (lower_runtime_predicate_value ctx env ~bound_vars origin)
  in
  let terms =
    results
    |> List.filter_map (fun (result : Expr_translate.result) -> result.term)
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

type runtime_predicate_analysis =
  | Runtime_predicate_ready of
      { guards : eq_condition list
      ; predicate_term : term
      ; components : exp list
      ; terms : term list
      ; input_sorts : sort list option
      ; bound_after_guards : string list
      ; diagnostics : Diagnostics.t list
      }
  | Runtime_predicate_needs_binding of
      { guards : eq_condition list
      ; diagnostics : Diagnostics.t list
      ; components : exp list
      ; terms : term list
      ; missing_sources : string list
      ; reason : string
      ; suggestion : string
      }
  | Runtime_predicate_bad_value of
      { guards : eq_condition list
      ; diagnostics : Diagnostics.t list
      }

let runtime_predicate_unsupported
    ?(blocked_witness_source_ids = [])
    ctx env ~bound_vars origin prem constructor diagnostics guards reason suggestion =
  { (empty_with_env ~bound_vars env) with
    eq_conditions = guards
  ; blocked_witness_source_ids
  ; diagnostics =
      diagnostics
      @ [ unsupported
            ~ctx
            ~origin
            ~constructor
            ~source_echo:(source_echo_prem prem)
            ~reason
            ~suggestion
        ()
        ]
  }

let runtime_predicate_blocked_by_prior_witness
    ctx env ~bound_vars origin prem diagnostics guards missing_sources =
  { (empty_with_env ~bound_vars env) with
    eq_conditions = guards
  ; diagnostics =
      diagnostics
      @ [ skipped
            ~ctx
            ~origin
            ~constructor:"Premise/RulePr/runtime-predicate/blocked-by-witness-search"
            ~source_echo:(source_echo_prem prem)
            ~reason:
              ("this predicate uses witness variable(s) that an earlier premise in the same source block was supposed to introduce, but that earlier witness search is still Unsupported: "
               ^ String.concat ", " missing_sources)
            ~suggestion:
              "Implement the earlier source-derived rewrite-backed local-existential helper; this dependent predicate will then be checked after the witness is introduced"
            ()
        ]
  }

let runtime_predicate_missing_sources bound components terms =
  List.combine components terms
  |> List.concat_map (fun (component, term) ->
    let missing =
      Condition_closure.term_vars term
      |> List.filter (fun var -> not (List.mem var bound))
    in
    if missing = [] then
      []
    else
      source_and_note_free_var_ids component)
  |> List.sort_uniq String.compare

let runtime_predicate_input_sorts components =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | component :: components ->
      (match Expr_translate.carrier_sort_of_typ component.note with
      | Some sort -> loop (sort :: acc) components
      | None -> None)
  in
  loop [] components

let analyze_runtime_predicate_args
    ctx env ~bound_vars origin rel_id exp relation_shape =
  let expected_count = List.length relation_shape.Relation_shape.components in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    Error
      (Printf.sprintf
         "runtime predicate relation premise does not match the referenced RelD signature component count %d without flattening source tuple structure"
         expected_count)
  | Some components ->
    let terms_opt, guards, diagnostics =
      lower_runtime_predicate_value_components ctx env ~bound_vars origin components
    in
    let guards =
      Condition_closure.normalize_binding_conditions
        (bound_vars |> List.map (fun var -> Var var))
        guards
    in
    match terms_opt with
    | None -> Ok (Runtime_predicate_bad_value { guards; diagnostics })
    | Some terms ->
      (match Condition_closure.conditions_admissible_bound bound_vars guards with
      | None ->
        Ok
          (Runtime_predicate_needs_binding
             { guards
             ; diagnostics
             ; components
             ; terms
             ; missing_sources = runtime_predicate_missing_sources bound_vars components terms
             ; reason =
                 "runtime predicate argument guards are not admissible from variables bound by the enclosing lhs or earlier premises; Bool predicates cannot introduce or search for their arguments"
             ; suggestion =
                 "Bind the predicate arguments through the source lhs or an earlier admissible premise; if the source premise needs an existential witness, lower it through a source-derived rewrite-backed search helper, not through a Bool predicate or single-witness function"
             })
      | Some bound_after_guards ->
        let predicate_term = relation_call rel_id terms in
        let missing =
          Condition_closure.term_vars predicate_term
          |> List.filter (fun var -> not (List.mem var bound_after_guards))
          |> List.sort_uniq String.compare
        in
        if missing = [] then
          Ok
            (Runtime_predicate_ready
               { guards
               ; predicate_term
               ; components
               ; terms
               ; input_sorts = runtime_predicate_input_sorts components
               ; bound_after_guards
               ; diagnostics
               })
        else
          Ok
            (Runtime_predicate_needs_binding
               { guards
               ; diagnostics
               ; components
               ; terms
               ; missing_sources =
                   runtime_predicate_missing_sources bound_after_guards components terms
               ; reason =
                   "runtime predicate premise would need to bind/search variable(s), but Bool predicates can only test already-bound values in Maude conditions: "
                   ^ String.concat ", " missing
               ; suggestion =
                   "Do not encode this predicate as a matching condition or deterministic witness function; keep it Unsupported until a source-derived rewrite-backed local-existential helper can introduce the witness before later guards use it"
               }))

let local_witness_arguments missing_sources components terms =
  match missing_sources with
  | [ witness_source_id ] ->
    let component_sort component =
      Expr_translate.carrier_sort_of_typ component.note
    in
    let rec terms_with_sorts components terms =
      match components, terms with
      | [], [] -> Some []
      | component :: components, term :: terms ->
        (match component_sort component, terms_with_sorts components terms with
        | Some sort, Some rest -> Some ((term, sort) :: rest)
        | None, _ | _, None -> None)
      | _ -> None
    in
    let rec loop index inputs_rev = function
      | [], [] -> None
      | component :: components, term :: terms ->
        (match component.it with
        | VarE id when id.it = witness_source_id ->
          (match component_sort component with
          | None -> None
          | Some witness_sort ->
            (match terms_with_sorts components terms with
            | None -> None
            | Some rest ->
              let input_pairs = List.rev inputs_rev @ rest in
              Some
                ( List.map fst input_pairs
                , List.map snd input_pairs
                , index
                , term
                , witness_sort )))
        | _ ->
          (match component_sort component with
          | None -> None
          | Some sort -> loop (index + 1) ((term, sort) :: inputs_rev) (components, terms)))
      | _ -> None
    in
    loop 0 [] (components, terms)
  | _ -> None

let runtime_predicate_relation ctx rel_id mixop =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id with
  | None -> None
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    let runtime_predicate =
      local_kind = relation_shape.Relation_shape.marker
      && Analysis.Relation_graph.eq_mixop relation.mixop mixop
      &&
      match relation_shape.Relation_shape.decision with
      | Relation_shape.Runtime_predicate _ -> true
      | Relation_shape.Static_validation _ ->
        Analysis.Function_graph.relation_is_runtime_demanded
          (Context.function_graph ctx)
          rel_id
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> false
    in
    if runtime_predicate then Some relation_shape else None

let direct_witness_index witness_source_id components =
  let rec loop index = function
    | [] -> None
    | component :: components ->
      if is_direct_var_exp witness_source_id component then
        Some index
      else
        loop (index + 1) components
  in
  loop 0 components

let local_witness_guides
    ctx
    env
    ~bound_vars
    origin
    ~witness_source_id
    ~witness_term
    ~witness_sort
    future_prems
  =
  let guide_of_prem prem =
    match prem.it with
    | RulePr (rel_id, [], mixop, exp) ->
      (match runtime_predicate_relation ctx rel_id.it mixop with
      | None -> None
      | Some relation_shape ->
        let expected_count =
          List.length relation_shape.Relation_shape.components
        in
        (match Analysis.Relation_graph.exp_components_for_count expected_count exp with
        | None -> None
        | Some components ->
          (match direct_witness_index witness_source_id components with
          | None -> None
          | Some guide_witness_index ->
            let witness_binding =
              { Expr_translate.term = witness_term
              ; sort = witness_sort
              ; typ = (List.nth components guide_witness_index).note
              }
            in
            let guide_env =
              Expr_translate.with_condition_bound_vars
                (Expr_translate.add_var env witness_source_id witness_binding)
                bound_vars
            in
            let terms_opt, guards, diagnostics =
              lower_value_components ctx guide_env origin components
            in
            (match
               ( terms_opt
               , guards
               , diagnostics
               , runtime_predicate_input_sorts components )
             with
            | Some guide_input_terms, [], [], Some guide_input_sorts ->
              Some
                { Runtime_search_helper.guide_rel_id = rel_id.it
                ; guide_source = Some (source_echo_prem prem)
                ; guide_input_terms
                ; guide_input_sorts
                ; guide_witness_index
                }
            | _ -> None))))
    | RulePr (_, _ :: _, _, _)
    | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None
  in
  future_prems |> List.filter_map guide_of_prem

let rec replace_term needle replacement term =
  if term = needle then
    replacement
  else
    match term with
    | Var _ | Const _ | Qid _ -> term
    | App (op, args) -> App (op, List.map (replace_term needle replacement) args)

let replace_condition needle replacement = function
  | EqCond (left, right) ->
    EqCond (replace_term needle replacement left, replace_term needle replacement right)
  | MatchCond (left, right) ->
    MatchCond (replace_term needle replacement left, replace_term needle replacement right)
  | MembershipCond (term, sort) ->
    MembershipCond (replace_term needle replacement term, sort)
  | BoolCond term -> BoolCond (replace_term needle replacement term)

let replace_capture_terms captures conditions =
  captures
  |> List.fold_left
       (fun conditions capture ->
         conditions
         |> List.map
              (replace_condition capture.Helper.call_term (Var capture.Helper.formal_var)))
       conditions

let filter_captures_by_call_vars used_vars captures =
  captures
  |> List.filter (fun capture ->
    Condition_closure.term_vars capture.Helper.call_term
    |> List.exists (fun var -> List.mem var used_vars))

type indexed_predicate_source =
  { index_source_id : string
  ; source_exp : exp
  ; source_term : term
  ; indexed_term : term
  }

let rec indexed_predicate_source missing_source component term =
  match component.it, term with
  | SubE (inner, _, _), _ | CvtE (inner, _, _), _ ->
    indexed_predicate_source missing_source inner term
  | IdxE (source_exp, index_exp), App ("index", [ source_term; _index_term ]) ->
    (match index_exp.it with
    | VarE index_id when index_id.it = missing_source ->
      Some { index_source_id = index_id.it; source_exp; source_term; indexed_term = term }
    | _ -> None)
  | _ -> None

let indexed_predicate_sources missing_source components terms =
  List.combine components terms
  |> List.filter_map (fun (component, term) ->
    indexed_predicate_source missing_source component term)

let indexed_predicate_candidates missing_sources escape_source_ids components terms =
  missing_sources
  |> List.filter (fun source_id -> not (List.mem source_id escape_source_ids))
  |> List.concat_map (fun source_id ->
    indexed_predicate_sources source_id components terms)
  |> List.sort_uniq (fun left right ->
    match String.compare left.index_source_id right.index_source_id with
    | 0 -> compare left.indexed_term right.indexed_term
    | order -> order)

let lower_indexed_predicate_exists
    ctx
    env
    ~bound_vars
    origin
    prem
    rel_id
    components
    terms
    guards
    diagnostics
    missing_sources
    escape_source_ids =
  let build indexed source_element_sort source_term =
    if
      not
        (vars_subset
           (Condition_closure.term_vars source_term)
           bound_vars)
    then
      None
    else
      let stem = helper_local_stem origin (source_echo_prem prem) in
      let helper_head_var =
        Naming.maude_var ~fallback:"HEAD" (stem ^ "-head")
      in
      let source_tail_var =
        Naming.maude_var ~fallback:"TAIL" (stem ^ "-tail")
      in
      let head_term = Var helper_head_var in
      let body_conditions =
        guards @ [ BoolCond (relation_call rel_id terms) ]
        |> List.map (replace_condition indexed.indexed_term head_term)
      in
      let body_used_vars =
        Condition_closure.external_vars_of_conditions
          [ helper_head_var ]
          body_conditions
      in
      let capture_ids =
        components
        |> List.concat_map source_and_note_free_var_ids
        |> List.filter (fun id -> id <> indexed.index_source_id)
        |> List.sort_uniq String.compare
      in
      let captures =
        capture_candidates env capture_ids
        |> make_captures stem
        |> filter_captures_by_call_vars body_used_vars
      in
      let body_conditions = replace_capture_terms captures body_conditions in
      let helper_bound = helper_head_var :: capture_vars captures in
      let body_external =
        Condition_closure.external_vars_of_conditions helper_bound body_conditions
      in
      if body_external <> [] then
        None
      else
        let helper_request =
          { Helper.kind =
              Helper.Iter_premise_exists_bool
                { source_shape =
                    { prem_source = source_echo_prem prem
                    ; indexed_source = source_echo_exp indexed.source_exp
                    ; source_typ_source =
                        Il.Print.string_of_typ indexed.source_exp.note
                    ; predicate_source = source_echo_prem prem
                    }
                ; index_source_id = indexed.index_source_id
                ; helper_head_var
                ; source_tail_var
                ; source_element_sort
                ; captures
                ; body_eq_conditions = body_conditions
                }
          ; reason = "finite indexed runtime-predicate existential over a source list"
          ; origin
          }
        in
        let helper_name = Helper.request (Context.helpers ctx) helper_request in
        let helper_call =
          app helper_name
            (source_term
             :: List.map (fun capture -> capture.Helper.call_term) captures)
        in
        Some
          (with_conditions
             env
             bound_vars
             [ BoolCond helper_call ]
             diagnostics)
  in
  match
    indexed_predicate_candidates
      missing_sources
      escape_source_ids
      components
      terms
  with
    | [ indexed ] ->
      (match flat_list_element_typ indexed.source_exp.note with
      | None -> None
      | Some source_element_typ ->
        (match Expr_translate.carrier_sort_of_typ source_element_typ with
        | None -> None
        | Some source_element_sort ->
          build indexed source_element_sort indexed.source_term))
    | _ -> None

let lower_runtime_predicate_rule_premise
    ctx
    env
    ~allow_runtime_search
    ~bound_vars
    ~blocked_witness_source_ids
    ~escape_source_ids
    ~future_prems
    origin
    prem
    rel_id
    exp
    relation_shape =
  match analyze_runtime_predicate_args ctx env ~bound_vars origin rel_id exp relation_shape with
  | Error reason ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-predicate/arity" prem reason
  | Ok (Runtime_predicate_ready
          { guards
          ; predicate_term
          ; terms
          ; input_sorts
          ; bound_after_guards
          ; diagnostics
          ; _
          }) ->
    (match Runtime_predicate_search.truth_plan ctx rel_id.it with
    | Runtime_predicate_search.Truth_not_needed ->
      { (empty_with_env ~bound_vars:bound_after_guards env) with
        eq_conditions = guards @ [ BoolCond predicate_term ]
      ; diagnostics
      }
    | truth_plan when allow_runtime_search ->
      (match input_sorts with
      | Some input_sorts ->
        (match
           Runtime_predicate_search.truth_helper_request
             ~input_terms:terms
             ~input_sorts
             truth_plan
         with
        | Some request ->
          let helper_name =
            Helper.request
              (Context.helpers ctx)
              { Helper.kind = Helper.Runtime_predicate_truth_search request
              ; reason = Runtime_truth_search_helper.reason request
              ; origin
              }
          in
          { (empty_with_env ~bound_vars:bound_after_guards env) with
            eq_conditions = guards
          ; rule_conditions =
              [ Runtime_truth_search_helper.rewrite_condition ~helper_name request ]
          ; runtime_truth_search_requests = [ request ]
          ; diagnostics
          }
        | None ->
          let diagnostic =
            Runtime_predicate_search.truth_diagnostic ctx rel_id.it
          in
          let constructor, reason, suggestion =
            match diagnostic with
            | None ->
              ( "Premise/RulePr/runtime-predicate/truth-search-needed"
              , "runtime predicate needs a rewrite-backed truth-search helper, but no source-complete helper request could be built"
              , "Keep this predicate Unsupported until its source closure can be materialized as rewrite-backed helper rules"
              )
            | Some diagnostic ->
              ( diagnostic.Runtime_predicate_search.constructor
              , diagnostic.Runtime_predicate_search.reason
              , diagnostic.Runtime_predicate_search.suggestion
              )
          in
          runtime_predicate_unsupported
            ctx
            env
            ~bound_vars
            origin
            prem
            constructor
            diagnostics
            guards
            reason
            suggestion)
      | None ->
        runtime_predicate_unsupported
          ctx
          env
          ~bound_vars
          origin
          prem
          "Premise/RulePr/runtime-predicate/truth-search-sort"
          diagnostics
          guards
          "runtime predicate needs a rewrite-backed truth-search helper, but at least one argument type has no Maude carrier sort"
          "Keep this predicate Unsupported until the source relation component types can be mapped to helper argument sorts")
    | _ ->
      let diagnostic =
        Runtime_predicate_search.truth_diagnostic ctx rel_id.it
      in
      let constructor, reason, suggestion =
        match diagnostic with
        | None ->
          ( "Premise/RulePr/runtime-predicate/truth-search-in-ceq"
          , "runtime predicate needs a rewrite-backed truth-search helper, but this premise is being lowered in a pure equational context"
          , "Use this predicate only inside a crl/helper context, or add an explicit rewrite-dependent carrier before lowering it"
          )
        | Some diagnostic ->
          ( diagnostic.Runtime_predicate_search.constructor
          , diagnostic.Runtime_predicate_search.reason
          , diagnostic.Runtime_predicate_search.suggestion
          )
      in
      runtime_predicate_unsupported
        ctx
        env
        ~bound_vars
        origin
        prem
        constructor
        diagnostics
        guards
        reason
        suggestion)
  | Ok (Runtime_predicate_needs_binding
          { guards
          ; diagnostics
          ; components
          ; terms
          ; missing_sources
          ; reason
          ; suggestion
          }) ->
    (match
       lower_indexed_predicate_exists
         ctx
         env
         ~bound_vars
         origin
         prem
         rel_id
         components
         terms
         guards
         diagnostics
         missing_sources
         escape_source_ids
     with
    | Some result -> result
    | None ->
      if
        missing_sources <> []
        && List.for_all
             (fun id -> List.mem id blocked_witness_source_ids)
             missing_sources
      then
        runtime_predicate_blocked_by_prior_witness
          ctx
          env
          ~bound_vars
          origin
          prem
          diagnostics
          guards
          missing_sources
      else
      (match
         Runtime_predicate_search.local_existential_plan
           ctx
           rel_id.it
           ~missing_sources
           ~escape_source_ids
           ~future_prems
      with
      | Some plan when allow_runtime_search ->
        (match local_witness_arguments missing_sources components terms with
        | Some (input_terms, input_sorts, witness_index, witness_term, witness_sort) ->
          let guides =
            match missing_sources with
            | [ witness_source_id ] ->
              local_witness_guides
                ctx
                env
                ~bound_vars
                origin
                ~witness_source_id
                ~witness_term
                ~witness_sort
                future_prems
            | [] | _ :: _ :: _ -> []
          in
          (match
             Runtime_predicate_search.helper_request
               ~input_terms
               ~input_sorts
               ~guides
               ~witness_index
               ~witness_term
               ~witness_sort
               plan
           with
        | Some request ->
          let helper_name =
            Helper.request
              (Context.helpers ctx)
              { Helper.kind = Helper.Runtime_predicate_search request
              ; reason = Runtime_search_helper.reason request
              ; origin
              }
          in
          let witness_vars = Condition_closure.term_vars witness_term in
          { (empty_with_env ~bound_vars:(normalize_vars (bound_vars @ witness_vars)) env)
            with
            eq_conditions = guards
          ; rule_conditions =
              [ Runtime_search_helper.rewrite_condition ~helper_name request ]
          ; runtime_search_requests = [ request ]
          ; diagnostics
          }
        | None ->
          let diagnostic =
            Runtime_predicate_search.binding_diagnostic
              ctx
              rel_id.it
              ~missing_sources
              ~escape_source_ids
              ~future_prems
          in
          let constructor, reason, suggestion, blocked_witness_source_ids =
            match diagnostic with
            | None ->
              "Premise/RulePr/runtime-predicate/binding-needed", reason, suggestion, []
            | Some diagnostic ->
              ( diagnostic.Runtime_predicate_search.constructor
              , diagnostic.Runtime_predicate_search.reason
              , diagnostic.Runtime_predicate_search.suggestion
              , diagnostic.Runtime_predicate_search.blocked_witness_source_ids )
          in
          runtime_predicate_unsupported
            ~blocked_witness_source_ids
            ctx
            env
            ~bound_vars
            origin
            prem
            constructor
            diagnostics
            guards
            reason
            suggestion)
        | None ->
          runtime_predicate_unsupported
            ctx
            env
            ~bound_vars
            origin
            prem
            "Premise/RulePr/runtime-predicate/binding-needed"
            diagnostics
            guards
            reason
            "Runtime search currently requires exactly one direct VarE witness argument; keep this premise Unsupported until a source-derived helper can preserve the more complex witness pattern")
      | _ ->
        let diagnostic =
          Runtime_predicate_search.binding_diagnostic
            ctx
            rel_id.it
            ~missing_sources
            ~escape_source_ids
            ~future_prems
        in
        let constructor, reason, suggestion, blocked_witness_source_ids =
          match diagnostic with
          | None ->
            "Premise/RulePr/runtime-predicate/binding-needed", reason, suggestion, []
          | Some diagnostic ->
            ( diagnostic.Runtime_predicate_search.constructor
            , diagnostic.Runtime_predicate_search.reason
            , diagnostic.Runtime_predicate_search.suggestion
            , diagnostic.Runtime_predicate_search.blocked_witness_source_ids )
        in
        runtime_predicate_unsupported
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem
          constructor
          diagnostics
          guards
          reason
          suggestion))
  | Ok (Runtime_predicate_bad_value { guards; diagnostics }) ->
    runtime_predicate_unsupported
      ctx
      env
      ~bound_vars
      origin
      prem
      "Premise/RulePr/runtime-predicate/value"
      diagnostics
      guards
      "runtime predicate premise arguments must lower as already-bound Maude values in this helper-free slice"
      "Keep this predicate premise Unsupported until a source-derived binding/complement helper is available"

let output_condition_for_pattern bound pattern subject =
  let pattern_vars = Condition_closure.term_vars pattern in
  if Condition_closure.is_match_pattern pattern then
    MatchCond (pattern, subject)
  else if vars_subset pattern_vars bound then
    EqCond (pattern, subject)
  else
    MatchCond (pattern, subject)

let lower_deterministic_rule_premise
    ctx env ~bound_vars origin prem rel_id exp
    (shape : Relation_shape.deterministic_shape) =
  let input_count = List.length shape.inputs in
  let expected_count = input_count + 1 in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic/arity" prem
      (Printf.sprintf
         "deterministic relation premise does not match the referenced RelD signature with %d input component(s) and one output component without flattening source tuple structure"
         input_count)
  | Some components ->
    let rec split n left right =
      if n = 0 then List.rev left, right
      else
        match right with
        | [] -> List.rev left, []
        | item :: rest -> split (n - 1) (item :: left) rest
    in
    let input_exps, output_exps = split input_count [] components in
    match output_exps with
    | [ output_exp ] ->
      let input_terms_opt, input_guards, input_diags =
        lower_value_components ctx env origin input_exps
      in
      let output_pattern =
        Expr_translate.lower_pattern_with_bindings ctx env origin output_exp
      in
      let output_sort_opt =
        Expr_translate.carrier_sort_of_typ shape.Relation_shape.output.typ
      in
      (match input_terms_opt, output_pattern.pattern_term, output_sort_opt with
      | Some input_terms, Some output_term, Some output_sort ->
        let binding_needed reason suggestion =
          { (empty_with_env ~bound_vars env) with
            eq_conditions = input_guards @ output_pattern.pattern_guards
          ; diagnostics =
              input_diags @ output_pattern.pattern_diagnostics
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/RulePr/deterministic/binding-needed"
                    ~source_echo:(source_echo_prem prem)
                    ~reason
                    ~suggestion
                    ()
                ]
          }
        in
        (match
           Condition_closure.conditions_admissible_bound bound_vars input_guards
         with
        | None ->
          binding_needed
            "deterministic relation input guards are not admissible before the relation result matching condition"
            "Bind the deterministic relation inputs through earlier source premises before calling the deterministic relation"
        | Some guard_bound ->
          let subject = relation_call rel_id input_terms in
          let missing =
            Condition_closure.term_vars subject
            |> List.filter (fun var -> not (List.mem var guard_bound))
            |> List.sort_uniq String.compare
          in
          if missing <> [] then
            binding_needed
              ("deterministic relation input value(s) are not bound before the result matching condition: "
               ^ String.concat ", " missing)
              "Keep this RulePr Unsupported until the source provides a prior binding premise or a source-derived search helper is implemented"
          else
            let result_var =
              deterministic_result_var origin rel_id output_sort
            in
            let result_condition = MatchCond (result_var, subject) in
            let condition =
              let bound_after_result =
                add_vars (Condition_closure.term_vars result_var) guard_bound
              in
              output_condition_for_pattern bound_after_result output_term result_var
            in
            let env_after =
              add_introduced_bindings env output_pattern.introduced_bindings
            in
            let conditions =
              input_guards @ [ result_condition; condition ]
              @ output_pattern.pattern_guards
            in
            { (empty_with_env
                 ~bound_vars:(conditions_bound_vars bound_vars conditions)
                 env_after) with
              eq_conditions = conditions
            ; diagnostics = input_diags @ output_pattern.pattern_diagnostics
            })
      | _ ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = input_guards @ output_pattern.pattern_guards
        ; diagnostics =
            input_diags @ output_pattern.pattern_diagnostics
            @ [ unsupported
                  ~ctx ~origin ~constructor:"Premise/RulePr/deterministic/output"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "deterministic relation premise requires all input expressions to lower as values, the output component to lower as a source-shaped pattern, and the output carrier sort to be known"
                  ~suggestion:
                    "Keep this premise Unsupported until a source-preserving inverse/pattern helper exists for the unsupported component"
                  ()
              ]
        })
    | _ ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic/output" prem
        "deterministic relation premise requires exactly one output component in this helper-free slice"

let lower_annotated_execution_equational_view_premise
    ctx env ~bound_vars origin prem rel_id exp
    (shape : Relation_shape.execution_shape) =
  let input_count = List.length shape.inputs in
  let output_count = List.length shape.outputs in
  let expected_count = input_count + output_count in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/equational-view/arity" prem
      (Printf.sprintf
         "annotated execution relation premise does not match the referenced RelD signature with %d input component(s) and %d output component(s) without flattening source tuple structure"
         input_count
         output_count)
  | Some components ->
    let rec split n left right =
      if n = 0 then List.rev left, right
      else
        match right with
        | [] -> List.rev left, []
        | item :: rest -> split (n - 1) (item :: left) rest
    in
    let input_exps, output_exps = split input_count [] components in
    let input_terms_opt, input_guards, input_diags =
      lower_value_components ctx env origin input_exps
    in
    let output_patterns =
      output_exps
      |> List.map (Expr_translate.lower_pattern_with_bindings ctx env origin)
    in
    let output_terms =
      output_patterns
      |> List.filter_map
           (fun (pattern : Expr_translate.pattern_result) -> pattern.pattern_term)
    in
    let output_guards =
      output_patterns
      |> List.map (fun pattern -> pattern.Expr_translate.pattern_guards)
      |> List.concat
    in
    let output_diags =
      output_patterns
      |> List.map (fun pattern -> pattern.Expr_translate.pattern_diagnostics)
      |> List.concat
    in
    let output_bindings =
      output_patterns
      |> List.map (fun pattern -> pattern.Expr_translate.introduced_bindings)
      |> List.concat
    in
    let output_pattern_opt, tuple_errors =
      match output_terms with
      | [ term ] when output_count = 1 -> Some term, []
      | terms when List.length terms = output_count ->
        tuple_pattern_from_components shape.outputs terms
      | _ -> None, []
    in
    let output_sort_opt =
      match shape.outputs with
      | [ component ] -> Expr_translate.carrier_sort_of_typ component.Relation_shape.typ
      | _ -> Some (sort "SpectecTerminal")
    in
    (match input_terms_opt, output_pattern_opt, output_sort_opt, tuple_errors with
    | Some input_terms, Some output_pattern, Some output_sort, [] ->
      let binding_needed reason suggestion =
        { (empty_with_env ~bound_vars env) with
          eq_conditions = input_guards @ output_guards
        ; diagnostics =
            input_diags @ output_diags
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/RulePr/equational-view/binding-needed"
                  ~source_echo:(source_echo_prem prem)
                  ~reason
                  ~suggestion
                  ()
              ]
        }
      in
      (match Condition_closure.conditions_admissible_bound bound_vars input_guards with
      | None ->
        binding_needed
          "annotated equational-view relation input guards are not admissible before the relation result matching condition"
          "Bind the relation inputs through earlier source premises before calling the annotated equational view"
      | Some guard_bound ->
        let subject = relation_equational_view_call rel_id input_terms in
        let missing =
          Condition_closure.term_vars subject
          |> List.filter (fun var -> not (List.mem var guard_bound))
          |> List.sort_uniq String.compare
        in
        if missing <> [] then
          binding_needed
            ("annotated equational-view relation input value(s) are not bound before the result matching condition: "
             ^ String.concat ", " missing)
            "Keep this RulePr Unsupported until the source provides a prior binding premise or a source-derived search helper is implemented"
        else
          let result_var =
            equational_view_result_var origin rel_id output_sort
          in
          let result_condition = MatchCond (result_var, subject) in
          let bound_after_result =
            add_vars (Condition_closure.term_vars result_var) guard_bound
          in
          let output_condition =
            output_condition_for_pattern bound_after_result output_pattern result_var
          in
          let env_after =
            add_introduced_bindings env output_bindings
          in
          let conditions =
            input_guards @ [ result_condition; output_condition ] @ output_guards
          in
          { (empty_with_env
               ~bound_vars:(conditions_bound_vars bound_vars conditions)
               env_after) with
            eq_conditions = conditions
          ; diagnostics = input_diags @ output_diags
          })
    | _ ->
      let tuple_error_reason =
        match tuple_errors with
        | [] ->
          "annotated equational-view relation requires all input expressions to lower as values and all output components to lower as source-shaped patterns"
        | errors -> String.concat "; " errors
      in
      { (empty_with_env ~bound_vars env) with
        eq_conditions = input_guards @ output_guards
      ; diagnostics =
          input_diags @ output_diags
          @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"Premise/RulePr/equational-view/output"
                ~source_echo:(source_echo_prem prem)
                ~reason:tuple_error_reason
                ~suggestion:
                  "Keep this premise Unsupported until the annotated equational view output can be represented by the existing tuple/sequence carrier"
                ()
            ]
      })

let lower_rule_premise
    ctx
    env
    ~allow_runtime_search
    ~bound_vars
    ~blocked_witness_source_ids
    ~future_prems
    ~escape_source_ids
    origin
    prem
    rel_id
    mixop =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/unresolved" prem
      ("relation premise references `" ^ rel_id.it ^ "`, but no matching RelD was found in the source index")
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    if local_kind <> relation_shape.Relation_shape.marker then
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/mixop" prem
        ("source relation marker mismatch: referenced relation is `"
         ^ relation_shape.Relation_shape.marker_text
         ^ "`, but this RulePr local mixop is `"
         ^ Analysis.Relation_graph.string_of_relation_kind local_kind
         ^ "`")
    else if not (Analysis.Relation_graph.eq_mixop relation.mixop mixop) then
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/mixop-skeleton" prem
        ("source relation mixop skeleton mismatch: referenced RelD `"
         ^ rel_id.it
         ^ "` uses `"
         ^ Analysis.Relation_graph.mixop_shape_text relation.mixop
         ^ "`, but this RulePr uses `"
         ^ Analysis.Relation_graph.mixop_shape_text mixop
         ^ "`")
    else
    (match relation_shape.Relation_shape.decision with
    | Relation_shape.Static_validation _ ->
      (match
         Analysis.Function_graph.relation_runtime_demand_reason
           (Context.function_graph ctx)
           rel_id.it
       with
      | Some runtime_reason ->
        (match prem.it with
        | RulePr (_, _, _, exp) ->
          lower_runtime_predicate_rule_premise
            ctx
            env
            ~allow_runtime_search
            ~bound_vars
            ~blocked_witness_source_ids
            ~escape_source_ids
            ~future_prems
            origin
            prem
            rel_id
            exp
            relation_shape
        | _ ->
          unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-demanded-predicate" prem
            ("relation is static by signature but runtime-demanded by the relation call graph: "
             ^ runtime_reason))
      | None ->
        skipped_prem ctx env ~bound_vars origin "Premise/RulePr/static-validation" prem
          ("static validation relation premise is discharged by the official validator in Runtime_after_external_validation; structural relation classification is "
           ^ relation_shape.Relation_shape.marker_text)
          "Keep the source premise in diagnostics/metadata; emit no runtime Maude condition for this validation-only premise")
    | Relation_shape.Runtime_predicate _ ->
      (match prem.it with
      | RulePr (_, _, _, exp) ->
        lower_runtime_predicate_rule_premise
          ctx
          env
          ~allow_runtime_search
          ~bound_vars
          ~blocked_witness_source_ids
          ~escape_source_ids
          ~future_prems
          origin
          prem
          rel_id
          exp
          relation_shape
      | _ ->
        unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-predicate" prem
          "runtime predicate premise lowering expected a RulePr AST node")
    | Relation_shape.Deterministic_candidate shape ->
      (match prem.it with
      | RulePr (_, _, _, exp) ->
        lower_deterministic_rule_premise
          ctx
          env
          ~bound_vars
          origin
          prem
          rel_id
          exp
          shape
      | _ ->
        unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic" prem
          "deterministic relation premise lowering expected a RulePr AST node")
    | Relation_shape.Execution shape ->
      if Analysis.Function_graph.relation_has_maude_equational_view relation then
        (match prem.it with
        | RulePr (_, _, _, exp) ->
          lower_annotated_execution_equational_view_premise
            ctx
            env
            ~bound_vars
            origin
            prem
            rel_id
            exp
            shape
        | _ ->
          unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/equational-view" prem
            "annotated equational-view lowering expected a RulePr AST node")
      else
        unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/execution" prem
          ("execution relation premise cannot be emitted inside eq/ceq/cmb conditions; structural relation classification is "
           ^ relation_shape.Relation_shape.marker_text
           ^ ", so this requires RelD lowering plus rewrite-dependent DecD/crl helper support or an explicit maude_equational_view annotation")
    | Relation_shape.Unknown reason ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/unknown" prem
        ("relation premise marker is not classified as validation, deterministic, or execution; structural relation classification is "
         ^ relation_shape.Relation_shape.marker_text
         ^ "; "
         ^ reason))

let lower_optional_if_iter_premise
    ctx env ~bound_vars origin prem body source_generator source_exp =
  let unsupported_optional_iter reason =
    unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/OptIf"
      ~source_echo:(source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the optional premise helper can preserve absent/present branches source-safely"
      ()
  in
  match flat_optional_element_typ source_exp.note with
  | None ->
    { (empty_with_env ~bound_vars env) with
      diagnostics =
        [ unsupported_optional_iter
            ("optional IfPr IterPr requires a flat optional source; source note is `"
             ^ Il.Print.string_of_typ source_exp.note
             ^ "`")
        ]
    }
  | Some source_element_typ ->
    (match Expr_translate.carrier_sort_of_typ source_element_typ with
    | None ->
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          [ unsupported_optional_iter
              "optional IfPr IterPr could not determine a Maude carrier for the optional element type"
          ]
      }
    | Some source_element_sort ->
      let source_result = Expr_translate.lower_sequence ctx env origin source_exp in
      (match source_result.term with
      | None ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = source_result.guards
        ; diagnostics = source_result.diagnostics
        }
      | Some source_term ->
        let source_bound =
          conditions_bound_vars bound_vars source_result.guards
        in
        if
          not
            (vars_subset
               (Condition_closure.term_vars source_term)
               source_bound)
        then
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_result.guards
          ; diagnostics =
              source_result.diagnostics
              @ [ unsupported_optional_iter
                    "optional premise source is not bound before the helper call; emitting a Bool helper condition would create a Maude used-before-bound variable"
                ]
          }
        else
          let stem = helper_local_stem origin (source_echo_prem prem) in
          let helper_head_var = "HEAD" ^ stem in
          let source_tail_var = "TAIL" ^ stem in
          let body_result_var = "BODY" ^ stem in
          let generator_binding =
            { Expr_translate.term = Var helper_head_var
            ; sort = source_element_sort
            ; typ = source_element_typ
            }
          in
          let body_source_ids =
            source_and_note_free_var_ids body
            |> List.filter (fun id -> id <> source_generator.it)
            |> List.sort_uniq String.compare
          in
          let captures =
            body_source_ids
            |> capture_candidates env
            |> make_captures stem
          in
          let helper_env =
            Expr_translate.add_var
              (capture_env captures)
              source_generator.it
              generator_binding
          in
          let body_result =
            Expr_translate.lower_bool_condition ctx helper_env origin body
          in
          (match body_result.term with
          | None ->
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_result.guards
            ; diagnostics = source_result.diagnostics @ body_result.diagnostics
            }
          | Some _ ->
              let body_vars =
                match body_result.term with
                | Some term ->
                  Condition_closure.external_vars_of_term_after_conditions
                    [ helper_head_var; body_result_var ]
                    term
                    body_result.guards
                | None -> []
              in
              let captures =
                captures |> filter_used_captures body_vars
              in
              let allowed_vars =
                helper_head_var :: capture_vars captures
              in
              let variable_diagnostics =
                if vars_subset body_vars allowed_vars then
                  []
                else
                  [ unsupported_optional_iter
                      "optional premise body references variables outside the helper head and captured closure variables"
                  ]
              in
              (match body_result.term, variable_diagnostics with
              | Some lowered_body, [] ->
                let helper_request =
                  { Helper.kind =
                      Helper.Iter_premise_opt_bool
                        { source_shape =
                            { prem_source = source_echo_prem prem
                            ; body_source = source_echo_exp body
                            ; source_source = source_echo_exp source_exp
                            ; source_typ_source = Il.Print.string_of_typ source_exp.note
                            }
                        ; generator_var = source_generator.it
                        ; helper_head_var
                        ; source_tail_var
                        ; body_result_var
                        ; source_element_sort
                        ; captures
                        ; lowered_body
                        ; body_eq_conditions = body_result.guards
                        }
                  ; reason = "optional IfPr IterPr Bool helper"
                  ; origin
                  }
                in
                let helper_name =
                  Helper.request (Context.helpers ctx) helper_request
                in
                let helper_call =
                  app helper_name
                    (source_term
                     :: List.map (fun capture -> capture.Helper.call_term) captures)
                in
                let caller_conditions =
                  source_result.guards
                  @ [ EqCond (is_opt source_term, Const "true")
                    ; BoolCond helper_call
                    ]
                in
                let caller_bound =
                  conditions_bound_vars bound_vars caller_conditions
                in
                let helper_missing_vars =
                  Condition_closure.term_vars helper_call
                  |> List.filter (fun var -> not (List.mem var caller_bound))
                  |> List.sort_uniq String.compare
                in
                if
                  helper_missing_vars = []
                then
                  with_conditions
                    env
                    bound_vars
                    caller_conditions
                    (source_result.diagnostics @ body_result.diagnostics)
                else
                  { (empty_with_env ~bound_vars env) with
                    eq_conditions = source_result.guards
                  ; diagnostics =
                      source_result.diagnostics @ body_result.diagnostics
                      @ [ unsupported_optional_iter
                            ("optional premise helper call contains variables that are not bound by earlier premise conditions: "
                             ^ String.concat ", " helper_missing_vars)
                        ]
                  }
              | _ ->
                { (empty_with_env ~bound_vars env) with
                  eq_conditions = source_result.guards
                ; diagnostics =
                    source_result.diagnostics @ body_result.diagnostics
                    @ variable_diagnostics
                }))))

let structural_static_validation_rule_premise ctx rel_id mixop =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
  | None -> None
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    if local_kind <> relation_shape.Relation_shape.marker
       || not (Analysis.Relation_graph.eq_mixop relation.mixop mixop)
    then
      None
    else
      match relation_shape.Relation_shape.decision with
      | Relation_shape.Static_validation reason -> Some reason
      | _ -> None

type static_validation_body =
  { reasons : string list
  ; has_relation : bool
  }

let validation_body reason has_relation =
  { reasons = [ reason ]; has_relation }

let rec static_validation_iter_body ctx prem =
  match prem.it with
  | IfPr _ -> Some (validation_body "source side condition" false)
  | RulePr (rel_id, [], mixop, _) ->
    (match structural_static_validation_rule_premise ctx rel_id mixop with
    | Some reason -> Some (validation_body reason true)
    | None -> None)
  | RulePr (_, _ :: _, _, _) -> None
  | IterPr (body, _) -> static_validation_iter_body ctx body
  | NegPr _ | LetPr _ | ElsePr -> None

let enclosing_static_validation_relation ctx =
  match Context.enclosing_path ctx with
  | relation_id :: _ ->
    (match
       Analysis.Function_graph.find_relation
         (Context.function_graph ctx)
         relation_id
     with
    | Some relation ->
      (match (Relation_shape.of_relation relation).Relation_shape.decision with
      | Relation_shape.Static_validation _ -> true
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> false)
    | None -> false)
  | [] -> false

let source_id_is_bound env bound_vars id =
  match Expr_translate.find_var env id with
  | None -> false
  | Some binding ->
    Condition_closure.term_vars binding.Expr_translate.term
    |> List.for_all (fun var -> List.mem var bound_vars)

let unbound_external_source_ids env ~bound_vars local_ids prem =
  prem_source_and_note_free_var_ids prem
  |> List.filter (fun id ->
    not (List.mem id local_ids) && not (source_id_is_bound env bound_vars id))
  |> List.sort_uniq String.compare

let iter_local_source_ids = function
  | ListN (_, Some id) -> [ id.it ]
  | Opt | List | List1 | ListN (_, None) -> []

let validation_local_generator_ids env ~bound_vars generators =
  generators
  |> List.filter_map (fun (id, source_exp) ->
    let source_ids = source_and_note_free_var_ids source_exp in
    if source_ids = []
       || List.exists
            (fun source_id -> not (source_id_is_bound env bound_vars source_id))
            source_ids
    then
      Some id.it
    else
      None)
  |> List.sort_uniq String.compare

let future_runtime_source_ids ctx prems =
  prems
  |> List.filter (fun prem ->
    match static_validation_iter_body ctx prem with
    | Some _ -> false
    | None -> true)
  |> List.concat_map prem_source_and_note_free_var_ids
  |> List.sort_uniq String.compare

let skip_eligible_static_validation_premise ctx prem =
  match prem.it with
  | RulePr (rel_id, [], mixop, _) ->
    Option.is_some (structural_static_validation_rule_premise ctx rel_id mixop)
  | RulePr (_, _ :: _, _, _) -> false
  | IterPr (body, _) -> Option.is_some (static_validation_iter_body ctx body)
  | IfPr _ | LetPr _ | ElsePr | NegPr _ -> false

let future_skipped_static_validation_source_ids ctx prems =
  prems
  |> List.filter (skip_eligible_static_validation_premise ctx)
  |> List.concat_map prem_source_and_note_free_var_ids
  |> List.sort_uniq String.compare

let mixop_has_validation_subtyping_marker mixop =
  Xl.Mixop.flatten mixop
  |> List.exists (fun atoms ->
    atoms
    |> List.exists (fun atom ->
      match atom.it with
      | Xl.Atom.TurnstileSub | Xl.Atom.Sub -> true
      | _ -> false))

let enclosing_relation_id ctx =
  match Context.enclosing_path ctx with
  | relation_id :: _ -> Some relation_id
  | [] -> None

let enclosing_relation_has_subtyping_marker ctx =
  match enclosing_relation_id ctx with
  | None -> false
  | Some relation_id ->
    (match
       Analysis.Function_graph.find_relation
         (Context.function_graph ctx)
         relation_id
     with
    | None -> false
    | Some relation -> mixop_has_validation_subtyping_marker relation.mixop)

let try_static_validation_rule_skip
    ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem rel_id mixop =
  match structural_static_validation_rule_premise ctx rel_id mixop with
  | None -> None
  | Some reason ->
    let enclosing_id = enclosing_relation_id ctx in
    if not (enclosing_static_validation_relation ctx) then
      None
    else if mixop_has_validation_subtyping_marker mixop then
      None
    else if enclosing_relation_has_subtyping_marker ctx then
      None
    else if enclosing_id = Some rel_id.it then
      None
    else
      let unbound_ids = unbound_external_source_ids env ~bound_vars [] prem in
      if unbound_ids = [] then
        None
      else
        let later_runtime_ids = future_runtime_source_ids ctx future_prems in
        let later_static_ids =
          future_skipped_static_validation_source_ids ctx future_prems
        in
        let later_ids =
          future_prems
          |> List.concat_map prem_source_and_note_free_var_ids
          |> List.sort_uniq String.compare
        in
        let escaping_ids =
          unbound_ids
          |> List.filter (fun id ->
            List.mem id escape_source_ids
            || List.mem id later_runtime_ids
            || (List.mem id later_ids && not (List.mem id later_static_ids)))
        in
        if escaping_ids <> [] then
          None
        else
          let reason =
            "static validation relation premise is discharged by the official validator in Runtime_after_external_validation; structural relation classification is "
            ^ reason
            ^ "; validation-local variable(s) are used only by later static-validation premises and do not escape runtime output or later runtime/non-validation conditions: "
            ^ String.concat ", " unbound_ids
          in
          Some
            (skipped_prem ctx env ~bound_vars origin
               "Premise/RulePr/static-validation"
               prem
               reason
               "Keep this validation-only witness premise in diagnostics/metadata; emit no runtime Maude condition for the local validation witness")

let try_static_validation_iter_skip
    ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators =
  match static_validation_iter_body ctx body with
  | None -> None
  | Some body_info ->
    let scoped_local_ids =
      iter_local_source_ids iter
      @ (generators |> List.map (fun (id, _source) -> id.it))
      |> List.sort_uniq String.compare
    in
    let guarded_local_ids =
      iter_local_source_ids iter
      @ validation_local_generator_ids env ~bound_vars generators
      |> List.sort_uniq String.compare
    in
    let unbound_ids =
      unbound_external_source_ids env ~bound_vars scoped_local_ids prem
    in
    let enclosing_static = enclosing_static_validation_relation ctx in
    if
      (not body_info.has_relation)
      && not enclosing_static
    then
      None
    else
      let later_ids = future_runtime_source_ids ctx future_prems in
      let guarded_ids =
        guarded_local_ids @ unbound_ids |> List.sort_uniq String.compare
      in
      if enclosing_static && guarded_ids = [] then
        None
      else
        let escaping_ids =
          guarded_ids
          |> List.filter (fun id ->
            List.mem id escape_source_ids || List.mem id later_ids)
        in
        if escaping_ids <> [] then
          None
        else
          let reason =
            "iterated static validation premise is discharged by the official validator in Runtime_after_external_validation; body structural classification is "
            ^ (body_info.reasons |> List.sort_uniq String.compare |> String.concat "; ")
            ^ "; validation-local variable(s) do not escape runtime output or later runtime/non-validation conditions: "
            ^ (match guarded_ids with
               | [] -> "<none>"
               | ids -> String.concat ", " ids)
          in
          Some
            (skipped_prem ctx env ~bound_vars origin
               "Premise/IterPr/static-validation"
               prem
               reason
               "Keep the iterated source premise in diagnostics/metadata; emit no runtime Maude condition for this validation-only IterPr")

let rec lower_list_iter_premise
    ctx env ~bound_vars origin prem body iter source_generator source_exp =
  let unsupported_list_iter reason =
    unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/List"
      ~source_echo:(source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the repeated premise can be lowered as source-shaped structural recursion without search or rewrite conditions"
      ()
  in
  match flat_list_element_typ source_exp.note with
  | None ->
    { (empty_with_env ~bound_vars env) with
      diagnostics =
        [ unsupported_list_iter
            ("list IterPr requires one flat list source; source note is `"
             ^ Il.Print.string_of_typ source_exp.note
             ^ "`")
        ]
    }
  | Some source_element_typ ->
    (match Expr_translate.carrier_sort_of_typ source_element_typ with
    | None ->
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          [ unsupported_list_iter
              "list IterPr could not determine a Maude carrier for the source element type"
          ]
      }
    | Some source_element_sort ->
      let source_result = Expr_translate.lower_sequence ctx env origin source_exp in
      (match source_result.term with
      | None ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = source_result.guards
        ; diagnostics = source_result.diagnostics
        }
      | Some source_term ->
        let source_bound =
          conditions_bound_vars bound_vars source_result.guards
        in
        if
          not
            (vars_subset
               (Condition_closure.term_vars source_term)
               source_bound)
        then
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_result.guards
          ; diagnostics =
              source_result.diagnostics
              @ [ unsupported_list_iter
                    "list IterPr source is not bound before the helper call; emitting a Bool helper condition would create a Maude used-before-bound variable"
                ]
          }
        else
          let stem = helper_local_stem origin (source_echo_prem prem) in
          let helper_head_var = "HEAD" ^ stem in
          let source_tail_var = "TAIL" ^ stem in
          let generator_binding =
            { Expr_translate.term = Var helper_head_var
            ; sort = source_element_sort
            ; typ = source_element_typ
            }
          in
          let body_source_ids =
            prem_free_var_ids body
            |> List.filter (fun id -> id <> source_generator.it)
            |> List.sort_uniq String.compare
          in
          let captures =
            body_source_ids
            |> capture_candidates env
            |> make_captures stem
          in
          let helper_env =
            Expr_translate.add_var
              (capture_env captures)
              source_generator.it
              generator_binding
          in
          let helper_bound =
            helper_head_var :: capture_vars captures
          in
          let body_result =
            translate_premise ctx helper_env ~bound_vars:helper_bound origin body
          in
          let body_input_bound = helper_bound in
          let body_used_vars =
            Condition_closure.external_vars_of_conditions
              [ helper_head_var ]
              body_result.eq_conditions
          in
          let captures =
            captures |> filter_used_captures body_used_vars
          in
          let helper_bound =
            helper_head_var :: capture_vars captures
          in
          let body_external =
            Condition_closure.external_vars_of_conditions
              helper_bound
              body_result.eq_conditions
          in
          let introduced_vars =
            body_result.bound_vars_after
            |> List.filter (fun var -> not (List.mem var body_input_bound))
            |> List.sort_uniq String.compare
          in
          let structural_diagnostics =
            body_external
            |> List.map (fun var_name ->
              unsupported_list_iter
                ("list IterPr helper body would need external variable `"
                 ^ var_name
                 ^ "` after captures; this would not be source-local structural recursion"))
          in
          let structural_diagnostics =
            if body_result.rule_conditions <> [] then
              unsupported_list_iter
                "list IterPr body lowers to a rewrite condition; rewrite conditions cannot appear inside this Bool helper equation"
              :: structural_diagnostics
            else
              structural_diagnostics
          in
          let structural_diagnostics =
            if body_result.has_else then
              unsupported_list_iter
                "list IterPr body contains ElsePr; otherwise/complement semantics need a separate source-derived helper"
              :: structural_diagnostics
            else
              structural_diagnostics
          in
          let structural_diagnostics =
            if body_result.let_bound_ids <> [] || introduced_vars <> [] then
              unsupported_list_iter
                ("list IterPr body introduces variable(s) that would escape the repeated check: "
                 ^ String.concat ", " introduced_vars)
              :: structural_diagnostics
            else
              structural_diagnostics
          in
          if diagnostics_have_fatal body_result.diagnostics
             || structural_diagnostics <> []
          then
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_result.guards
            ; diagnostics =
                source_result.diagnostics @ body_result.diagnostics
                @ structural_diagnostics
            }
          else
            let helper_request =
              { Helper.kind =
                  Helper.Iter_premise_list_bool
                    { source_shape =
                        { prem_source = source_echo_prem prem
                        ; body_source = source_echo_prem body
                        ; source_source = source_echo_exp source_exp
                        ; source_typ_source = Il.Print.string_of_typ source_exp.note
                        ; iter_source = Il.Print.string_of_iter iter
                        }
                    ; generator_var = source_generator.it
                    ; helper_head_var
                    ; source_tail_var
                    ; source_element_sort
                    ; captures
                    ; body_eq_conditions = body_result.eq_conditions
                    }
              ; reason = "list IterPr structural Bool helper"
              ; origin
              }
            in
            let helper_name =
              Helper.request (Context.helpers ctx) helper_request
            in
            let helper_call =
              app helper_name
                (source_term
                 :: List.map (fun capture -> capture.Helper.call_term) captures)
            in
            let iter_guards =
              match iter with
              | List -> []
              | List1 -> [ BoolCond (app "_=/=_" [ source_term; Const "eps" ]) ]
              | ListN (n_exp, None) ->
                let n_result = Expr_translate.lower_value ctx env origin n_exp in
                (match n_result.term with
                | Some n_term ->
                  n_result.guards @ [ EqCond (app "len" [ source_term ], n_term) ]
                | None -> n_result.guards)
              | ListN (_, Some _) | Opt -> []
            in
            let caller_conditions =
              source_result.guards @ iter_guards @ [ BoolCond helper_call ]
            in
            let helper_missing_vars =
              Condition_closure.external_vars_of_conditions
                bound_vars
                caller_conditions
            in
            if helper_missing_vars = [] then
              with_conditions
                env
                bound_vars
                caller_conditions
                (source_result.diagnostics @ body_result.diagnostics)
            else
              { (empty_with_env ~bound_vars env) with
                eq_conditions = source_result.guards
              ; diagnostics =
                  source_result.diagnostics @ body_result.diagnostics
                  @ [ unsupported_list_iter
                        ("list IterPr helper call contains variables that are not bound by earlier premise conditions: "
                         ^ String.concat ", " helper_missing_vars)
                    ]
              }))

and lower_zip_iter_premise ctx env ~bound_vars origin prem body iter generators =
  let unsupported_zip_iter reason =
    unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/Zip"
      ~source_echo:(source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the lockstep repeated premise can be lowered as source-shaped structural recursion without search or rewrite conditions"
      ()
  in
  let stem = helper_local_stem origin (source_echo_prem prem) in
  let generator_ids = generators |> List.map (fun (id, _exp) -> id.it) in
  let lower_source index (source_generator, source_exp) =
    match zip_source_descriptor source_exp.note with
    | None ->
      Error
        [ unsupported_zip_iter
            ("zip IterPr requires every source to be a flat list or boundary-preserving nested T** list; source `"
             ^ source_generator.it
             ^ "` has note `"
             ^ Il.Print.string_of_typ source_exp.note
             ^ "`")
        ]
    | Some (source_item_shape, source_element_typ) ->
      (match Expr_translate.carrier_sort_of_typ source_element_typ with
      | None ->
        Error
          [ unsupported_zip_iter
              ("zip IterPr could not determine a Maude carrier for source `"
               ^ source_generator.it
               ^ "`")
          ]
      | Some source_element_sort ->
        let source_result =
          Expr_translate.lower_sequence ctx env origin source_exp
        in
        (match source_result.term with
        | None -> Error source_result.diagnostics
        | Some source_term ->
          let suffix =
            "_"
            ^ Naming.maude_var
                ~fallback:("GEN" ^ string_of_int index)
                source_generator.it
          in
          Ok
            ( source_generator
            , source_exp
            , source_result
            , source_term
            , source_item_shape
            , source_element_typ
            , source_element_sort
            , "HEAD" ^ stem ^ suffix
            , "TAIL" ^ stem ^ suffix )))
  in
  let rec collect index acc diagnostics = function
    | [] ->
      if diagnostics = [] then Ok (List.rev acc) else Error diagnostics
    | generator :: generators ->
      (match lower_source index generator with
      | Ok source -> collect (index + 1) (source :: acc) diagnostics generators
      | Error source_diagnostics ->
        collect (index + 1) acc (diagnostics @ source_diagnostics) generators)
  in
  match collect 0 [] [] generators with
  | Error diagnostics ->
    { (empty_with_env ~bound_vars env) with diagnostics }
  | Ok sources ->
    let source_guards =
      sources
      |> List.concat_map (fun (_, _, source_result, _, _, _, _, _, _) ->
        source_result.Expr_translate.guards)
    in
    let source_diagnostics =
      sources
      |> List.concat_map (fun (_, _, source_result, _, _, _, _, _, _) ->
        source_result.Expr_translate.diagnostics)
    in
    let source_bound = conditions_bound_vars bound_vars source_guards in
    let unbound_source_vars =
      sources
      |> List.concat_map (fun (_id, _exp, _source_result, source_term, _, _, _, _, _) ->
        Condition_closure.term_vars source_term)
      |> List.filter (fun var -> not (List.mem var source_bound))
      |> List.sort_uniq String.compare
    in
    if unbound_source_vars <> [] then
      { (empty_with_env ~bound_vars env) with
        eq_conditions = source_guards
      ; diagnostics =
          source_diagnostics
          @ [ unsupported_zip_iter
                ("zip IterPr source term uses variable(s) before binding: "
                 ^ String.concat ", " unbound_source_vars)
            ]
      }
    else
      let generator_bindings =
        sources
        |> List.map
             (fun (source_generator, _source_exp, _source_result, _source_term,
                   _source_item_shape, source_element_typ, source_element_sort,
                   helper_head_var, _tail_var) ->
               ( source_generator.it
               , { Expr_translate.term = Var helper_head_var
                 ; sort = source_element_sort
                 ; typ = source_element_typ
                 } ))
      in
      let helper_heads =
        sources
        |> List.map (fun (_, _, _, _, _, _, _, helper_head_var, _) -> helper_head_var)
      in
      let body_source_ids =
        prem_free_var_ids body
        |> List.filter (fun id -> not (List.mem id generator_ids))
        |> List.sort_uniq String.compare
      in
      let captures =
        body_source_ids
        |> capture_candidates env
        |> make_captures stem
      in
      let helper_env =
        capture_env captures
        |> fun env ->
        generator_bindings
        |> List.fold_left
             (fun helper_env (id, binding) ->
               Expr_translate.add_var helper_env id binding)
             env
      in
      let helper_bound =
        helper_heads @ capture_vars captures
      in
      let body_result =
        translate_premise ctx helper_env ~bound_vars:helper_bound origin body
      in
      let body_input_bound = helper_bound in
      let body_used_vars =
        Condition_closure.external_vars_of_conditions
          helper_heads
          body_result.eq_conditions
      in
      let captures =
        captures |> filter_used_captures body_used_vars
      in
      let helper_bound =
        helper_heads @ capture_vars captures
      in
      let body_external =
        Condition_closure.external_vars_of_conditions
          helper_bound
          body_result.eq_conditions
      in
      let introduced_vars =
        body_result.bound_vars_after
        |> List.filter (fun var -> not (List.mem var body_input_bound))
        |> List.sort_uniq String.compare
      in
      let structural_diagnostics =
        body_external
        |> List.map (fun var_name ->
          unsupported_zip_iter
            ("zip IterPr helper body would need external variable `"
             ^ var_name
             ^ "` after captures; this would not be source-local structural recursion"))
      in
      let structural_diagnostics =
        if body_result.rule_conditions <> [] then
          unsupported_zip_iter
            "zip IterPr body lowers to a rewrite condition; rewrite conditions cannot appear inside this Bool helper equation"
          :: structural_diagnostics
        else
          structural_diagnostics
      in
      let structural_diagnostics =
        if body_result.has_else then
          unsupported_zip_iter
            "zip IterPr body contains ElsePr; otherwise/complement semantics need a separate source-derived helper"
          :: structural_diagnostics
        else
          structural_diagnostics
      in
      let structural_diagnostics =
        if body_result.let_bound_ids <> [] || introduced_vars <> [] then
          unsupported_zip_iter
            ("zip IterPr body introduces variable(s) that would escape the repeated check: "
             ^ String.concat ", " introduced_vars)
          :: structural_diagnostics
        else
          structural_diagnostics
      in
      if diagnostics_have_fatal body_result.diagnostics
         || structural_diagnostics <> []
      then
        { (empty_with_env ~bound_vars env) with
          eq_conditions = source_guards
        ; diagnostics =
            source_diagnostics @ body_result.diagnostics
            @ structural_diagnostics
        }
      else
        let helper_sources =
          sources
          |> List.map
               (fun (source_generator, source_exp, _source_result, _source_term,
                     source_item_shape, _source_element_typ, source_element_sort,
                     helper_head_var, source_tail_var) ->
                 { Helper.source_shape =
                     { generator_source_id = source_generator.it
                     ; source_source = source_echo_exp source_exp
                     ; source_typ_source = Il.Print.string_of_typ source_exp.note
                     }
                 ; source_item_shape
                 ; helper_head_var
                 ; source_tail_var
                 ; source_element_sort
                 })
        in
        let helper_request =
          { Helper.kind =
              Helper.Iter_premise_zip_bool
                { source_shape =
                    { prem_source = source_echo_prem prem
                    ; body_source = source_echo_prem body
                    ; iter_source = Il.Print.string_of_iter iter
                    ; sources =
                        helper_sources
                        |> List.map (fun (source : Helper.iter_zip_source) ->
                          source.Helper.source_shape)
                    }
                ; sources = helper_sources
                ; captures
                ; body_eq_conditions = body_result.eq_conditions
                }
          ; reason = "zip IterPr structural Bool helper"
          ; origin
          }
        in
        let helper_name = Helper.request (Context.helpers ctx) helper_request in
        let helper_call =
          app helper_name
            ((sources
              |> List.map (fun (_, _, _, source_term, _, _, _, _, _) -> source_term))
             @ List.map (fun capture -> capture.Helper.call_term) captures)
        in
        let source_terms =
          sources
          |> List.map (fun (_, _, _, source_term, _, _, _, _, _) -> source_term)
        in
        let same_length_guards =
          match source_terms with
          | [] | [ _ ] -> []
          | first :: rest ->
            rest
            |> List.map (fun source_term ->
              EqCond (app "len" [ source_term ], app "len" [ first ]))
        in
        let iter_guards =
          match iter with
          | List -> same_length_guards
          | List1 ->
            same_length_guards
            @ (source_terms
               |> List.map (fun source_term ->
                 BoolCond (app "_=/=_" [ source_term; Const "eps" ])))
          | ListN (n_exp, None) ->
            let n_result = Expr_translate.lower_value ctx env origin n_exp in
            (match n_result.term with
            | Some n_term ->
              n_result.guards
              @ (sources
                 |> List.map (fun (_, _, _, source_term, _, _, _, _, _) ->
                   EqCond (app "len" [ source_term ], n_term)))
            | None -> n_result.guards)
          | ListN (_, Some _) | Opt -> []
        in
        let caller_conditions =
          source_guards @ iter_guards @ [ BoolCond helper_call ]
        in
        let helper_missing_vars =
          Condition_closure.external_vars_of_conditions
            bound_vars
            caller_conditions
        in
        if helper_missing_vars = [] then
          with_conditions
            env
            bound_vars
            caller_conditions
            (source_diagnostics @ body_result.diagnostics)
        else
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_guards
          ; diagnostics =
              source_diagnostics @ body_result.diagnostics
              @ [ unsupported_zip_iter
                    ("zip IterPr helper call contains variables that are not bound by earlier premise conditions: "
                     ^ String.concat ", " helper_missing_vars)
                ]
          }

and try_binding_map_iter_premise ctx env ~bound_vars origin prem body iter generators =
  let targets = binding_map_targets env ~bound_vars generators in
  let lower_indexed_listn_target count_exp index_id target =
    let stem = helper_local_stem origin (source_echo_prem prem) in
    let body_result_var = "OUT" ^ stem in
    let count_var = "N" ^ stem in
    let index_var = "I" ^ stem in
    let target_generator_id = target.target_generator.it in
    let generator_ids = generators |> List.map (fun (id, _) -> id.it) in
    let count_binding =
      match count_exp.it with
      | VarE count_id ->
        Some
          ( count_id.it
          , { Expr_translate.term = Var count_var
            ; sort = sort "Nat"
            ; typ = count_exp.note
            } )
      | _ -> None
    in
    let local_source_ids =
      let count_ids =
        match count_binding with
        | Some (count_id, _) -> [ count_id ]
        | None -> []
      in
      index_id.it :: target_generator_id :: (count_ids @ generator_ids)
    in
    let body_source_ids =
      prem_source_and_note_free_var_ids body
      @ source_and_note_free_var_ids count_exp
      @ source_and_note_free_var_ids target.target_source_exp
      |> List.filter (fun id -> not (List.mem id local_source_ids))
      |> List.sort_uniq String.compare
    in
    let captures =
      body_source_ids |> capture_candidates env |> make_captures stem
    in
    let add_count_binding helper_env =
      match count_binding with
      | Some (count_id, binding) ->
        Expr_translate.add_var helper_env count_id binding
      | None -> helper_env
    in
    let helper_env =
      capture_env captures
      |> add_count_binding
      |> fun helper_env ->
      Expr_translate.add_var helper_env index_id.it
        { Expr_translate.term = Var index_var
        ; sort = sort "Nat"
        ; typ = NumT `NatT $ index_id.at
        }
      |> fun helper_env ->
      Expr_translate.add_var helper_env target_generator_id
        { Expr_translate.term = Var body_result_var
        ; sort = target.target_element_sort
        ; typ = target.target_element_typ
        }
    in
    let helper_bound = count_var :: index_var :: capture_vars captures in
    let body_result =
      translate_premise ctx helper_env ~bound_vars:helper_bound origin body
    in
    let body_initial_bound = helper_bound in
    match take_match_binding body_result_var body_result.eq_conditions with
    | None ->
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            body_result.diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IterPr/ListNBindingMap/body"
                  ~source_echo:(source_echo_prem body)
                  ~reason:
                    "indexed ListN binding-map body did not introduce the target element through a matching condition"
                  ~suggestion:
                    "Keep this premise Unsupported until the body equality can bind the target element source-locally"
                  ()
              ]
        }
	    | Some (lowered_body, body_eq_conditions) ->
	      let helper_conditions =
	        MatchCond (Var body_result_var, lowered_body) :: body_eq_conditions
	      in
	      let body_used_vars =
	        Condition_closure.external_vars_of_conditions
	          [ body_result_var; count_var; index_var ]
	          helper_conditions
	      in
	      let captures = captures |> filter_used_captures body_used_vars in
	      let helper_bound = count_var :: index_var :: capture_vars captures in
      let helper_bound_with_output = body_result_var :: helper_bound in
      let body_external =
        Condition_closure.external_vars_of_conditions
          helper_bound_with_output
          helper_conditions
      in
	      let introduced_vars =
	        body_result.bound_vars_after
	        |> List.filter (fun var ->
	          var <> body_result_var && not (List.mem var body_initial_bound))
	        |> List.sort_uniq String.compare
	      in
	      let helper_bound_after =
	        Condition_closure.conditions_admissible_bound
	          helper_bound
	          helper_conditions
	      in
	      let helper_failure_reasons =
	        [ (match helper_bound_after with
	           | None -> Some "conditions are not Maude-admissible in helper order"
	           | Some body_bound_after ->
	             if List.mem body_result_var body_bound_after then
	               None
	             else
	               Some
	                 ("target variable `" ^ body_result_var
	                  ^ "` is not bound by helper conditions"))
	        ; (match body_external with
	           | [] -> None
	           | vars ->
	             Some
	               ("helper body still references uncaptured variable(s): "
	                ^ String.concat ", " vars))
	        ; (match introduced_vars with
	           | [] -> None
	           | vars ->
	             Some
	               ("helper body introduces extra variable(s): "
	                ^ String.concat ", " vars))
	        ; if body_result.rule_conditions = [] then
	            None
	          else
	            Some "helper body produced rewrite/rule conditions"
	        ; if body_result.has_else then
	            Some "helper body contains ElsePr"
	          else
	            None
	        ; if body_result.let_bound_ids = [] then
	            None
	          else
	            Some "helper body contains source LetPr binding"
	        ; if diagnostics_have_fatal body_result.diagnostics then
	            Some "helper body produced fatal diagnostics"
	          else
	            None
	        ]
	        |> List.filter_map (fun reason -> reason)
	      in
	      (match helper_bound_after with
	      | Some body_bound_after
	        when List.mem body_result_var body_bound_after
	             && body_external = []
             && introduced_vars = []
             && body_result.rule_conditions = []
             && not body_result.has_else
             && body_result.let_bound_ids = []
             && not (diagnostics_have_fatal body_result.diagnostics) ->
        if not (Condition_closure.is_match_pattern target.target_source_term) then
          None
        else
          let count_result =
            Expr_translate.lower_numeric_guard_value ctx env origin count_exp
          in
          (match count_result.term with
          | None -> None
          | Some count_term ->
            let helper_request =
              { Helper.kind =
                  Helper.Iter_listn
                    { source_shape =
                        { iter_source = source_echo_prem prem
                        ; body_source = source_echo_prem body
                        ; count_source = source_echo_exp count_exp
                        ; count_typ_source = Il.Print.string_of_typ count_exp.note
                        ; output_typ_source =
                            Il.Print.string_of_typ target.target_source_exp.note
                        ; mode = Helper.Indexed_from_zero
                        }
                    ; call_shape = Helper.Source_then_captures
	      ; count_var
                    ; index_var = Some index_var
                    ; body_result_var
                    ; output_item_shape = Helper.Output_flat_terminal
                    ; captures
                    ; lowered_body
                    ; body_eq_conditions
                    }
              ; reason = "indexed ListN IterPr binding-map helper"
              ; origin
              }
            in
            let helper_name =
              Helper.request (Context.helpers ctx) helper_request
            in
            let helper_call =
              app helper_name
                (count_term
                 :: Const "0"
                 :: List.map (fun capture -> capture.Helper.call_term) captures)
            in
            let caller_conditions =
              count_result.guards
              @ [ MatchCond (target.target_source_term, helper_call) ]
            in
            if
              Condition_closure.external_vars_of_conditions
                bound_vars
                caller_conditions
              = []
            then
              let result =
                with_conditions
                  env
                  bound_vars
                  caller_conditions
                  (count_result.diagnostics @ body_result.diagnostics)
              in
              Some
                { result with
                  env_after =
                    Expr_translate.add_var
                      result.env_after
                      target.target_source_id.it
                      target.target_source_binding
                }
            else
              None)
      | _ ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              body_result.diagnostics
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/IterPr/ListNBindingMap/body"
	                    ~source_echo:(source_echo_prem body)
	                    ~reason:
	                      ("indexed ListN binding-map body equality is not admissible inside the source-local helper"
	                       ^
	                       if helper_failure_reasons = [] then
	                         ""
	                       else
	                         ": " ^ String.concat "; " helper_failure_reasons)
	                    ~suggestion:
	                      "Keep this premise Unsupported until the body has only equation conditions over the index, target, and captures"
	                    ()
                ]
          })
  in
  match iter, body.it, targets with
  | ListN (_count_exp, Some index_id), _, _ ->
    let targets =
      targets
      |> List.filter (fun target -> target.target_generator.it <> index_id.it)
    in
    (match body.it, targets with
    | IfPr ({ it = CmpE (`EqOp, _, _left, _right); _ }), [ target ] ->
      (match lower_indexed_listn_target _count_exp index_id target with
      | Some result -> Some result
      | None ->
        Some
          (unsupported_prem
             ctx
             env
             ~bound_vars
             origin
             "Premise/IterPr/ListNBindingMap"
             prem
             "indexed ListN binding-map shape was detected, but the body equality could not be lowered to a source-local binding-map helper"))
    | IfPr ({ it = CmpE (`EqOp, _, _, _); _ }), [] ->
      Some
        (unsupported_prem
           ctx
           env
           ~bound_vars
           origin
           "Premise/IterPr/ListNBindingMap"
           prem
           "indexed ListN binding-map premise has no unbound output sequence target after ignoring the index generator")
    | IfPr ({ it = CmpE (`EqOp, _, _, _); _ }), _ :: _ :: _ ->
      Some
        (unsupported_prem
           ctx
           env
           ~bound_vars
           origin
           "Premise/IterPr/ListNBindingMap"
           prem
           "indexed ListN binding-map premise has more than one unbound output sequence target")
    | _ -> None)
  | List, IfPr ({ it = CmpE (`EqOp, _, left, right); _ }), [ target ] ->
    let target_generator_id = target.target_generator.it in
    let target_on_left = is_direct_var_exp target_generator_id left in
    let target_on_right = is_direct_var_exp target_generator_id right in
    if target_on_left = target_on_right then
      None
    else
      let input_generators =
        generators
        |> List.filter (fun (generator_id, _) ->
          generator_id.it <> target_generator_id)
      in
      (match input_generators with
      | [ source_generator, source_exp ] ->
        (match
           zip_source_descriptor source_exp.note,
           Expr_translate.lower_sequence ctx env origin source_exp
         with
        | Some (source_item_shape, source_element_typ), source_result ->
          (match
             Expr_translate.carrier_sort_of_typ source_element_typ,
             source_result.term
           with
          | Some source_element_sort, Some source_term
            when not (diagnostics_have_fatal source_result.diagnostics) ->
            let source_bound =
              conditions_bound_vars bound_vars source_result.guards
            in
            if
              not
                (vars_subset
                   (Condition_closure.term_vars source_term)
                   source_bound)
            then
              None
            else
              let stem = helper_local_stem origin (source_echo_prem prem) in
              let suffix =
                "_"
                ^ Naming.maude_var ~fallback:"GEN" source_generator.it
              in
              let helper_head_var = "HEAD" ^ stem ^ suffix in
              let source_tail_var = "TAIL" ^ stem ^ suffix in
              let body_result_var = "OUT" ^ stem in
              let generator_ids =
                generators |> List.map (fun (id, _) -> id.it)
              in
              let body_source_ids =
                prem_free_var_ids body
                |> List.filter (fun id -> not (List.mem id generator_ids))
                |> List.sort_uniq String.compare
              in
              let captures =
                body_source_ids
                |> capture_candidates env
                |> make_captures stem
              in
              let helper_env =
                capture_env captures
                |> fun helper_env ->
                Expr_translate.add_var helper_env source_generator.it
                  { Expr_translate.term = Var helper_head_var
                  ; sort = source_element_sort
                  ; typ = source_element_typ
                  }
                |> fun helper_env ->
                Expr_translate.add_var helper_env target_generator_id
                  { Expr_translate.term = Var body_result_var
                  ; sort = target.target_element_sort
                  ; typ = target.target_element_typ
                  }
              in
              let helper_bound =
                helper_head_var :: capture_vars captures
              in
              let body_result =
                translate_premise ctx helper_env ~bound_vars:helper_bound origin body
              in
              (match take_match_binding body_result_var body_result.eq_conditions with
              | None -> None
	              | Some (lowered_body, body_eq_conditions) ->
	              let helper_conditions =
	                MatchCond (Var body_result_var, lowered_body) :: body_eq_conditions
	              in
              let body_used_vars =
                Condition_closure.external_vars_of_conditions
                  (body_result_var :: [ helper_head_var ])
                  helper_conditions
              in
              let captures =
                captures |> filter_used_captures body_used_vars
              in
              let helper_bound =
                helper_head_var :: capture_vars captures
              in
              let helper_bound_with_output =
                body_result_var :: helper_bound
              in
              let body_external =
                Condition_closure.external_vars_of_conditions
                  helper_bound_with_output
                  helper_conditions
              in
              let introduced_vars =
                body_result.bound_vars_after
                |> List.filter (fun var ->
                  var <> body_result_var && not (List.mem var helper_bound))
              in
              (match
                 Condition_closure.conditions_admissible_bound
                   helper_bound
                   helper_conditions
               with
              | Some body_bound_after
                when List.mem body_result_var body_bound_after
                     && body_external = []
                     && introduced_vars = []
                     && body_result.rule_conditions = []
                     && not body_result.has_else
                     && body_result.let_bound_ids = []
                     && not (diagnostics_have_fatal body_result.diagnostics) ->
                if not (Condition_closure.is_match_pattern target.target_source_term) then
                  None
                else
                let helper_request =
                  { Helper.kind =
                      Helper.Iter_map
                        { source_shape =
                            { iter_source = source_echo_prem prem
                            ; body_source = source_echo_prem body
                            ; source_source = source_echo_exp source_exp
                            ; output_typ_source =
                                Il.Print.string_of_typ target.target_source_exp.note
                            ; source_typ_source =
                                Il.Print.string_of_typ source_exp.note
                            }
                        ; call_shape = Helper.Source_then_captures
                        ; generator_var = source_generator.it
                        ; helper_head_var
                        ; source_tail_var
                        ; body_result_var
                        ; source_item_shape
                        ; output_item_shape = Helper.Output_flat_terminal
                        ; source_element_sort
                        ; captures
                        ; lowered_body
                        ; body_eq_conditions
                        }
                  ; reason = "IterPr binding-map helper"
                  ; origin
                  }
                in
                let helper_name =
                  Helper.request (Context.helpers ctx) helper_request
                in
                let helper_call =
                  app helper_name
                    (source_term
                     :: List.map (fun capture -> capture.Helper.call_term) captures)
                in
                let caller_conditions =
                  source_result.guards
                  @ [ MatchCond (target.target_source_term, helper_call) ]
                in
                if
                  Condition_closure.external_vars_of_conditions
                    bound_vars
                    caller_conditions
                  = []
                then
                  let result =
                    with_conditions
                      env
                      bound_vars
                      caller_conditions
                      (source_result.diagnostics @ body_result.diagnostics)
                  in
                  Some
                    { result with
                      env_after =
                        Expr_translate.add_var
                          result.env_after
                          target.target_source_id.it
                          target.target_source_binding
                    }
                else
                  None
              | _ -> None))
          | _ -> None)
        | _ -> None)
      | [] | _ :: _ :: _ -> None)
  | _ -> None

and lower_iter_premise
    ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators =
  match
    try_static_validation_iter_skip
      ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators
  with
  | Some result -> result
  | None ->
  match try_binding_map_iter_premise ctx env ~bound_vars origin prem body iter generators with
  | Some result -> result
  | None ->
    match iter, generators, body.it with
    | Opt, [ source_generator, source_exp ], IfPr body_exp ->
      lower_optional_if_iter_premise
        ctx env ~bound_vars origin prem body_exp source_generator source_exp
    | (List | List1 | ListN (_, None)), [ source_generator, source_exp ], _ ->
      lower_list_iter_premise
        ctx env ~bound_vars origin prem body iter source_generator source_exp
    | (List | List1 | ListN (_, None)), _ :: _ :: _, _ ->
      lower_zip_iter_premise ctx env ~bound_vars origin prem body iter generators
    | _ ->
      unsupported_prem ctx env ~bound_vars origin "Premise/IterPr" prem
        "iterated premises require all/optional/ListN premise helpers; this slice supports optional IfPr, one-source list all, and flat lockstep list zip helpers"

and translate_premise
    ?(allow_runtime_search = false)
    ?(future_prems = [])
    ?(escape_source_ids = [])
    ?(blocked_witness_source_ids = [])
    ctx
    env
    ~bound_vars
    parent_origin
    prem =
  let origin = origin_for_premise parent_origin prem in
  let env = Expr_translate.with_condition_bound_vars env bound_vars in
  match prem.it with
  | IfPr exp -> lower_if_premise ctx env ~bound_vars origin exp
  | LetPr (quants, lhs, rhs) ->
    let ids =
      quants
      |> List.filter_map (fun quant ->
        match quant.it with
        | ExpP (id, _) -> Some id.it
        | TypP _ | DefP _ | GramP _ -> None)
    in
    let lhs_result = Expr_translate.lower_pattern_with_bindings ctx env origin lhs in
    let rhs_result = Expr_translate.lower_value ctx env origin rhs in
    (match lhs_result.pattern_term, rhs_result.term with
    | Some lhs_term, Some rhs ->
      let env_after =
        add_introduced_bindings ~ids env lhs_result.introduced_bindings
      in
      let conditions = rhs_result.guards @ [ MatchCond (lhs_term, rhs) ] @ lhs_result.pattern_guards in
      { (with_conditions
           env_after
           bound_vars
           conditions
           (lhs_result.pattern_diagnostics @ rhs_result.diagnostics))
        with
        let_bound_ids = [ ids ]
      }
    | _ ->
      { (empty_with_env ~bound_vars env) with
        let_bound_ids = [ ids ]
      ; diagnostics =
          lhs_result.pattern_diagnostics @ rhs_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Premise/LetPr"
                ~source_echo:(source_echo_prem prem)
                ~reason:
                  ("LetPr could not be lowered; outbound ids preserved in premise metadata: "
                   ^ String.concat ", " ids)
                ()
            ]
      })
  | ElsePr -> { (empty_with_env ~bound_vars env) with has_else = true }
  | RulePr (rel_id, args, mixop, _exp) ->
    if args <> [] then
      unsupported_rulepr_args ctx env ~bound_vars origin prem rel_id args
    else
    (match
       try_static_validation_rule_skip
         ctx
         env
         ~bound_vars
         ~future_prems
         ~escape_source_ids
         origin
         prem
         rel_id
         mixop
     with
    | Some result -> result
    | None ->
      lower_rule_premise
        ctx
        env
        ~allow_runtime_search
        ~bound_vars
        ~blocked_witness_source_ids
        ~future_prems
        ~escape_source_ids
        origin
        prem
        rel_id
        mixop)
  | IterPr (body, (iter, generators)) ->
    lower_iter_premise
      ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators
  | NegPr _ ->
    unsupported_prem ctx env ~bound_vars origin "Premise/NegPr" prem
      "negated premises require a total Bool/complement helper, which is outside this pure DecD slice"

let translate_premises
    ?(allow_runtime_search = false)
    ctx env ?(bound_conditions = []) ?(escape_source_ids = []) ~bound_terms origin prems =
  let bound_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> normalize_vars
    |> fun vars -> conditions_bound_vars vars bound_conditions
  in
  let stalled_fatal_diagnostics stalled =
    stalled
    |> List.concat_map (fun (_prem, result) ->
      result.diagnostics |> List.filter Diagnostics.is_fatal)
  in
  let no_progress_result acc stalled =
    match stalled_fatal_diagnostics stalled with
    | _ :: _ as diagnostics -> { acc with diagnostics = acc.diagnostics @ diagnostics }
    | [] ->
      (match stalled with
      | [] -> acc
      | (prem, result) :: _ ->
        let prem_origin = origin_for_premise origin prem in
        { acc with
          diagnostics =
            acc.diagnostics @ result.diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin:prem_origin
                  ~constructor:"Premise/dependency-cycle"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "premise conditions cannot be ordered so every generated Maude condition uses only variables bound by the enclosing lhs or earlier admissible premises"
                  ~suggestion:
                    "Keep this premise block Unsupported until the source dependency cycle is removed or a source-derived rewrite/search helper can introduce the witness"
                  ()
              ]
        })
  in
  let rec pass acc progressed deferred = function
    | [] ->
      (match List.rev deferred with
      | [] -> acc
      | pending when progressed -> pass acc false [] (List.map fst pending)
      | stalled -> no_progress_result acc stalled)
    | prem :: rest ->
      let future_prems = rest @ (List.rev_map fst deferred) in
      let result =
        translate_premise
          ~allow_runtime_search
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids:acc.blocked_witness_source_ids
          ctx
          acc.env_after
          ~bound_vars:acc.bound_vars_after
          origin
          prem
      in
      if premise_result_has_fatal result
         && result_is_deferrable_listn_admissibility result
      then
        pass acc progressed ((prem, result) :: deferred) rest
      else
        pass (append acc result) true deferred rest
  in
  let result = pass (empty_with_env ~bound_vars env) false [] prems in
  { result with
    env_after =
      Expr_translate.with_condition_bound_vars
        result.env_after
        result.bound_vars_after
  }
