open Il.Ast
open Maude_ir
open Util.Source

module Request = Helper_request

open Helper_capture
open Premise_result

let app name args = App (name, args)

let diagnostics_have_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

type target =
  { target_generator : id
  ; target_source_id : id
  ; target_source_exp : exp
  ; target_source_term : term
  ; target_source_binding : Expr_env.binding
  ; target_element_typ : typ
  ; target_element_sort : sort
  }

let rec is_direct_var_exp var exp =
  match exp.it with
  | VarE id -> id.it = var
  | OptE (Some inner) -> is_direct_var_exp var inner
  | _ -> false

let targets names env ~bound_vars generators =
  generators
  |> List.filter_map (fun (target_generator, target_source_exp) ->
    match
      Premise_state.unbound_direct_var env ~bound_vars target_source_exp,
      Premise_shape.zip_source_descriptor target_source_exp.note
    with
    | Some target_source_id, Some (_item_shape, target_element_typ) ->
      (match Expr_translate.carrier_sort_of_typ target_element_typ with
      | Some target_element_sort ->
        let source_binding =
          match Expr_env.find env target_source_id.it with
          | Some binding -> Some (binding.term, binding)
          | None ->
            Premise_state.typed_var_for_exp
              names target_source_id target_source_exp
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

let lower_indexed_listn_target
    names ~lower_body ctx env ~bound_vars origin ~prem ~body generators count_exp index_id target =
  let target_generator_id = target.target_generator.it in
  let generator_ids = generators |> List.map (fun (id, _) -> id.it) in
  let count_id =
    match count_exp.it with
    | VarE count_id -> Some count_id.it
    | _ -> None
  in
  let local_source_ids =
    index_id.it :: target_generator_id
    :: (Option.to_list count_id @ generator_ids)
  in
  let body_source_ids =
    Source_free_vars.prem_and_note_ids body
    @ Source_free_vars.exp_and_note_ids count_exp
    @ Source_free_vars.exp_and_note_ids target.target_source_exp
    |> List.filter (fun id -> not (List.mem id local_source_ids))
    |> List.sort_uniq String.compare
  in
  let helper_names =
    Local_name.reserve_sources
      Local_name.empty (local_source_ids @ body_source_ids)
  in
  let body_result_var =
    Local_name.source_qualified_name
      helper_names target_generator_id (sort_ref target.target_element_sort)
  in
  let count_var, helper_names =
    match count_id with
    | Some count_id ->
      ( Local_name.source_qualified_name
          helper_names count_id (sort_ref (sort "Nat"))
      , helper_names )
    | None ->
      Local_name.fresh_qualified_name
        helper_names Local_name.Count (sort_ref (sort "Nat"))
  in
  let index_var =
    Local_name.source_qualified_name
      helper_names index_id.it (sort_ref (sort "Nat"))
  in
  let count_binding =
    Option.map
      (fun count_id ->
        ( count_id
        , { Expr_env.term = Var count_var
          ; sort = sort "Nat"
          ; typ = count_exp.note
          } ))
      count_id
  in
  let captures =
    body_source_ids
    |> capture_candidates env
    |> make_captures helper_names
  in
  let add_count_binding helper_env =
    match count_binding with
    | Some (count_id, binding) -> Expr_env.add helper_env count_id binding
    | None -> helper_env
  in
  let helper_env =
    capture_env captures
    |> add_count_binding
    |> fun helper_env ->
    Expr_env.add helper_env index_id.it
      { Expr_env.term = Var index_var
      ; sort = sort "Nat"
      ; typ = NumT `NatT $ index_id.at
      }
    |> fun helper_env ->
    Expr_env.add helper_env target_generator_id
      { Expr_env.term = Var body_result_var
      ; sort = target.target_element_sort
      ; typ = target.target_element_typ
      }
  in
  let helper_bound = count_var :: index_var :: capture_vars captures in
  let body_result, names =
    lower_body names ctx helper_env ~bound_vars:helper_bound origin body
  in
  let body_initial_bound = helper_bound in
  match
    Premise_state.take_match_binding body_result_var body_result.eq_conditions
  with
  | None ->
    Some
      ( { (empty_with_env ~bound_vars env) with
        diagnostics =
          body_result.diagnostics
          @ [ Premise_diagnostic.unsupported
                ~ctx
                ~origin
                ~constructor:"Premise/IterPr/ListNBindingMap/body"
                ~source_echo:(Premise_diagnostic.source_echo_prem body)
                ~reason:
                  "indexed ListN binding-map body did not introduce the target element through a matching condition"
                ~suggestion:
                  "Keep this premise Unsupported until the body equality can bind the target element source-locally"
                ()
            ]
        }
      , names )
  | Some (lowered_body, body_eq_conditions) ->
    let helper_conditions =
      MatchCond (Var body_result_var, lowered_body) :: body_eq_conditions
    in
    let body_used_vars =
      Condition_closure.external_vars_of_conditions
        ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
        [ body_result_var; count_var; index_var ]
        helper_conditions
    in
    let captures = captures |> filter_used_captures body_used_vars in
    let helper_bound = count_var :: index_var :: capture_vars captures in
    let helper_bound_with_output = body_result_var :: helper_bound in
    let body_external =
      Condition_closure.external_vars_of_conditions
        ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
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
      Condition_admissibility.conditions_admissible_bound
        ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
        helper_bound helper_conditions
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
      ; if body_result.has_else then Some "helper body contains ElsePr" else None
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
      if not
           (Condition_closure.is_match_pattern
              ~constructor_op:
                (Condition_closure.source_constructor_certificate ctx)
              target.target_source_term) then
        None
      else
        let count_result =
          Expr_translate.lower_numeric_guard_value ctx env origin count_exp
        in
        (match count_result.term with
        | None -> None
        | Some count_term ->
          let helper_request =
            { Request.kind =
                Request.Iter_listn
                  { source_shape =
                      { iter_source = Premise_diagnostic.source_echo_prem prem
                      ; body_source = Premise_diagnostic.source_echo_prem body
                      ; count_source = Premise_diagnostic.source_echo_exp count_exp
                      ; count_typ_source = Il.Print.string_of_typ count_exp.note
                      ; output_typ_source =
                          Il.Print.string_of_typ target.target_source_exp.note
                      ; mode = Request.Indexed_from_zero
                      }
                  ; call_shape = Request.Source_then_captures
                  ; count_var
                  ; index_var = Some index_var
                  ; body_result_var
                  ; output_item_shape = Request.Output_flat_terminal
                  ; captures
                  ; lowered_body
                  ; body_eq_conditions
                  }
            ; reason = "indexed ListN IterPr binding-map helper"
            ; origin
            }
          in
          let helper_name = Helper.request (Context.helpers ctx) helper_request in
          let helper_call =
            app helper_name
              (count_term
               :: Const "0"
               :: List.map (fun capture -> capture.Request.call_term) captures)
          in
          let caller_conditions =
            count_result.guards
            @ [ MatchCond (target.target_source_term, helper_call) ]
          in
          if
            Condition_closure.external_vars_of_conditions
              ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
              bound_vars caller_conditions
            = []
          then
            let result =
              Premise_state.with_conditions
                ctx
                env
                bound_vars
                caller_conditions
                (count_result.diagnostics @ body_result.diagnostics)
            in
            Some
              ( { result with
                env_after =
                  Expr_env.add
                    result.env_after
                    target.target_source_id.it
                    target.target_source_binding
                }
              , names )
          else
            None)
    | _ ->
      Some
        ( { (empty_with_env ~bound_vars env) with
          diagnostics =
            body_result.diagnostics
            @ [ Premise_diagnostic.unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IterPr/ListNBindingMap/body"
                  ~source_echo:(Premise_diagnostic.source_echo_prem body)
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
          }
        , names ))

let lower_list_target
    names ~lower_body ctx env ~bound_vars origin ~prem ~body generators left right target =
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
    match input_generators with
    | [ source_generator, source_exp ] ->
      (match
         Premise_shape.zip_source_descriptor source_exp.note,
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
            Condition_closure.conditions_bound_vars
              ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
              bound_vars source_result.guards
          in
          if
            not
              (Condition_closure.vars_subset
                 (Condition_closure.term_vars source_term)
                 source_bound)
          then
            None
          else
            let generator_ids = generators |> List.map (fun (id, _) -> id.it) in
            let body_source_ids =
              Source_free_vars.prem_ids body
              |> List.filter (fun id -> not (List.mem id generator_ids))
              |> List.sort_uniq String.compare
            in
            let helper_names =
              Local_name.reserve_sources
                Local_name.empty (generator_ids @ body_source_ids)
            in
            let helper_head_var =
              Local_name.source_qualified_name
                helper_names source_generator.it (sort_ref source_element_sort)
            in
            let source_tail_var, helper_names =
              Local_name.fresh_qualified_name
                helper_names Local_name.Tail
                (sort_ref (sort "SpectecTerminals"))
            in
            let body_result_var =
              Local_name.source_qualified_name
                helper_names target_generator_id
                (sort_ref target.target_element_sort)
            in
            let captures =
              body_source_ids
              |> capture_candidates env
              |> make_captures helper_names
            in
            let helper_env =
              capture_env captures
              |> fun helper_env ->
              Expr_env.add helper_env source_generator.it
                { Expr_env.term = Var helper_head_var
                ; sort = source_element_sort
                ; typ = source_element_typ
                }
              |> fun helper_env ->
              Expr_env.add helper_env target_generator_id
                { Expr_env.term = Var body_result_var
                ; sort = target.target_element_sort
                ; typ = target.target_element_typ
                }
            in
            let helper_bound = helper_head_var :: capture_vars captures in
            let body_result, names =
              lower_body names ctx helper_env ~bound_vars:helper_bound origin body
            in
            (match
               Premise_state.take_match_binding
                 body_result_var body_result.eq_conditions
             with
            | None -> None
            | Some (lowered_body, body_eq_conditions) ->
              let helper_conditions =
                MatchCond (Var body_result_var, lowered_body) :: body_eq_conditions
              in
              let body_used_vars =
                Condition_closure.external_vars_of_conditions
                  ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
                  (body_result_var :: [ helper_head_var ])
                  helper_conditions
              in
              let captures = captures |> filter_used_captures body_used_vars in
              let helper_bound = helper_head_var :: capture_vars captures in
              let helper_bound_with_output = body_result_var :: helper_bound in
              let body_external =
                Condition_closure.external_vars_of_conditions
                  ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
                  helper_bound_with_output
                  helper_conditions
              in
              let introduced_vars =
                body_result.bound_vars_after
                |> List.filter (fun var ->
                  var <> body_result_var && not (List.mem var helper_bound))
              in
              (match
                 Condition_admissibility.conditions_admissible_bound
                   ~constructor_op:
                     (Condition_closure.source_constructor_certificate ctx)
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
                if not
                     (Condition_closure.is_match_pattern
                        ~constructor_op:
                          (Condition_closure.source_constructor_certificate ctx)
                        target.target_source_term) then
                  None
                else
                  let helper_request =
                    { Request.kind =
                        Request.Iter_map
                          { source_shape =
                              { iter_source = Premise_diagnostic.source_echo_prem prem
                              ; body_source = Premise_diagnostic.source_echo_prem body
                              ; source_source = Premise_diagnostic.source_echo_exp source_exp
                              ; output_typ_source =
                                  Il.Print.string_of_typ target.target_source_exp.note
                              ; source_typ_source =
                                  Il.Print.string_of_typ source_exp.note
                              }
                          ; call_shape = Request.Source_then_captures
                          ; generator_var = source_generator.it
                          ; helper_head_var
                          ; source_tail_var
                          ; body_result_var
                          ; source_item_shape
                          ; output_item_shape = Request.Output_flat_terminal
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
                       :: List.map (fun capture -> capture.Request.call_term) captures)
                  in
                  let caller_conditions =
                    source_result.guards
                    @ [ MatchCond (target.target_source_term, helper_call) ]
                  in
                  if
                    Condition_closure.external_vars_of_conditions
                      ~constructor_op:
                        (Condition_closure.source_constructor_certificate ctx)
                      bound_vars
                      caller_conditions
                    = []
                  then
                    let result =
                      Premise_state.with_conditions
                        ctx
                        env
                        bound_vars
                        caller_conditions
                        (source_result.diagnostics @ body_result.diagnostics)
                    in
                    Some
                      ( { result with
                        env_after =
                          Expr_env.add
                            result.env_after
                            target.target_source_id.it
                            target.target_source_binding
                        }
                      , names )
                  else
                    None
              | _ -> None))
        | _ -> None)
      | _ -> None)
    | [] | _ :: _ :: _ -> None

let lower_multi_list_targets
    names ~lower_body ctx env ~bound_vars origin ~prem ~body generators targets =
  let target_ids = List.map (fun target -> target.target_generator.it) targets in
  let input_generators =
    generators
    |> List.filter (fun (id, _) -> not (List.mem id.it target_ids))
  in
  let generator_ids = List.map (fun (id, _) -> id.it) generators in
  let body_source_ids =
    Source_free_vars.prem_ids body
    |> List.filter (fun id -> not (List.mem id generator_ids))
    |> List.sort_uniq String.compare
  in
  let helper_names =
    Local_name.reserve_sources
      Local_name.empty (generator_ids @ body_source_ids)
  in
  let prepare_source helper_names (id, exp) =
    match
      Premise_shape.zip_source_descriptor exp.note,
      Expr_translate.lower_sequence ctx env origin exp
    with
    | Some (item_shape, element_typ), result ->
      (match Expr_translate.carrier_sort_of_typ element_typ, result.term with
      | Some element_sort, Some term
        when not (diagnostics_have_fatal result.diagnostics) ->
        let source_tail_var, helper_names =
          Local_name.fresh_qualified_name
            helper_names Local_name.Tail
            (sort_ref (sort "SpectecTerminals"))
        in
        ( Some
            ( id, exp, result, term, element_typ,
              ({ Request.source_shape =
                   { generator_source_id = id.it
                   ; source_source = Premise_diagnostic.source_echo_exp exp
                   ; source_typ_source = Il.Print.string_of_typ exp.note
                   }
               ; source_item_shape = item_shape
               ; helper_head_var =
                   Local_name.source_qualified_name
                     helper_names id.it (sort_ref element_sort)
               ; source_tail_var
               ; source_element_sort = element_sort
               } : Request.iter_zip_source) )
        , helper_names )
      | _ -> None, helper_names)
    | None, _ -> None, helper_names
  in
  let prepare_output helper_names target =
    match Premise_shape.zip_source_descriptor target.target_source_exp.note with
    | None -> None, helper_names
    | Some (source_item_shape, element_typ) ->
      (match Expr_translate.carrier_sort_of_typ element_typ with
      | None -> None, helper_names
      | Some source_element_sort ->
        let source_tail_var, helper_names =
          Local_name.fresh_qualified_name
            helper_names Local_name.Tail
            (sort_ref (sort "SpectecTerminals"))
        in
        ( Some
            ( target,
              ({ Request.source_item_shape
               ; helper_head_var =
                   Local_name.source_qualified_name
                     helper_names target.target_generator.it
                     (sort_ref source_element_sort)
               ; source_tail_var
               ; source_element_sort
               } : Request.iter_premise_binding_output),
              element_typ )
        , helper_names ))
  in
  let rec prepare_all prepare helper_names prepared = function
    | [] -> List.rev prepared, helper_names
    | item :: items ->
      let prepared_item, helper_names = prepare helper_names item in
      prepare_all prepare helper_names (prepared_item :: prepared) items
  in
  let sources, helper_names =
    prepare_all prepare_source helper_names [] input_generators
  in
  let outputs, helper_names =
    prepare_all prepare_output helper_names [] targets
  in
  if input_generators = []
     || List.exists Option.is_none sources
     || List.exists Option.is_none outputs
  then
    None
  else
    let sources = List.filter_map Fun.id sources in
    let outputs = List.filter_map Fun.id outputs in
    let source_guards =
      sources
      |> List.concat_map (fun (_, _, result, _, _, _) -> result.Expr_result.guards)
    in
    let source_diagnostics =
      sources
      |> List.concat_map (fun (_, _, result, _, _, _) -> result.Expr_result.diagnostics)
    in
    let source_terms = List.map (fun (_, _, _, term, _, _) -> term) sources in
    let source_bound =
      Condition_closure.conditions_bound_vars
        ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
        bound_vars source_guards
    in
    if
      source_terms
      |> List.concat_map Condition_closure.term_vars
      |> List.exists (fun var -> not (List.mem var source_bound))
    then
      None
    else
      let captures =
        body_source_ids
        |> capture_candidates env
        |> make_captures helper_names
      in
      let helper_env =
        sources
        |> List.fold_left
             (fun env (id, _, _, _, element_typ,
                       (source : Request.iter_zip_source)) ->
               Expr_env.add env id.it
                 { Expr_env.term = Var source.Request.helper_head_var
                 ; sort = source.source_element_sort
                 ; typ = element_typ
                 })
             (capture_env captures)
      in
      let helper_env =
        outputs
        |> List.fold_left
             (fun env (target,
                       (output : Request.iter_premise_binding_output),
                       element_typ) ->
               Expr_env.add env target.target_generator.it
                 { Expr_env.term = Var output.Request.helper_head_var
                 ; sort = output.source_element_sort
                 ; typ = element_typ
                 })
             helper_env
      in
      let input_heads =
        List.map
          (fun (_, _, _, _, _, (source : Request.iter_zip_source)) ->
            source.Request.helper_head_var)
          sources
      in
      let output_heads =
        List.map
          (fun (_, (output : Request.iter_premise_binding_output), _) ->
            output.Request.helper_head_var)
          outputs
      in
      let helper_bound = input_heads @ capture_vars captures in
      let body_result, names =
        lower_body names ctx helper_env ~bound_vars:helper_bound origin body
      in
      let body_conditions =
        Condition_closure.normalize_binding_conditions
          ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
          (List.map (fun var -> Var var) helper_bound)
          body_result.eq_conditions
      in
      let captures =
        let used =
          Condition_closure.external_vars_of_conditions
            ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
            input_heads body_conditions
        in
        filter_used_captures used captures
      in
      let helper_bound = input_heads @ capture_vars captures in
      let body_bound_after =
        Condition_admissibility.conditions_admissible_bound
          ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
          helper_bound body_conditions
      in
      let introduced =
        body_result.bound_vars_after
        |> List.filter (fun var ->
          not (List.mem var helper_bound) && not (List.mem var output_heads))
        |> List.sort_uniq String.compare
      in
      if body_result.rule_conditions <> []
         || body_result.has_else
         || body_result.let_bound_ids <> []
         || diagnostics_have_fatal body_result.diagnostics
         || introduced <> []
         || (match body_bound_after with
            | None -> true
            | Some bound ->
              List.exists (fun output -> not (List.mem output bound)) output_heads)
      then
        None
      else if
        List.exists
          (fun (target, _, _) ->
            not
              (Condition_closure.is_match_pattern
                 ~constructor_op:
                   (Condition_closure.source_constructor_certificate ctx)
                 target.target_source_term))
          outputs
      then
        None
      else
        let helper_sources =
          List.map (fun (_, _, _, _, _, source) -> source) sources
        in
        let helper_outputs = List.map (fun (_, output, _) -> output) outputs in
        let source_shapes =
          List.map
            (fun (source : Request.iter_zip_source) -> source.Request.source_shape)
            helper_sources
        in
        let request =
          { Request.kind =
              Request.Iter_premise_zip_binding
                { source_shape =
                    { prem_source = Premise_diagnostic.source_echo_prem prem
                    ; body_source = Premise_diagnostic.source_echo_prem body
                    ; iter_source = Il.Print.string_of_iter List
                    ; sources = source_shapes
                    }
                ; sources = helper_sources
                ; outputs = helper_outputs
                ; captures
                ; body_eq_conditions = body_conditions
                }
          ; reason = "lockstep IterPr multi-output binding-map helper"
          ; origin
          }
        in
        let helper_name = Helper.request (Context.helpers ctx) request in
        let helper_call =
          app helper_name
            (source_terms
             @ List.map (fun capture -> capture.Request.call_term) captures)
        in
        let tuple_pattern =
          outputs
          |> List.map (fun (target, _, _) -> app "seq" [ target.target_source_term ])
          |> function
          | [] -> app "tuple" [ Const "eps" ]
          | head :: tail -> app "tuple" [ List.fold_left (fun acc item -> app "_ _" [ acc; item ]) head tail ]
        in
        let length_guards =
          match source_terms with
          | [] | [ _ ] -> []
          | first :: rest ->
            List.map
              (fun term -> EqCond (app "len" [ term ], app "len" [ first ]))
              rest
        in
        let caller_conditions =
          source_guards @ length_guards @ [ MatchCond (tuple_pattern, helper_call) ]
        in
        if
          Condition_closure.external_vars_of_conditions
            ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
            bound_vars caller_conditions
          <> []
        then
          None
        else
          let result =
            Premise_state.with_conditions
              ctx env bound_vars caller_conditions
              (source_diagnostics @ body_result.diagnostics)
          in
          let env_after =
            outputs
            |> List.fold_left
                 (fun env (target, _, _) ->
                   Expr_env.add
                     env target.target_source_id.it target.target_source_binding)
                 result.env_after
          in
          Some ({ result with env_after }, names)

let try_lower names ~lower_body ctx env ~bound_vars origin ~prem ~body iter generators =
  let targets = targets names env ~bound_vars generators in
  match iter, body.it, targets with
  | ListN (count_exp, Some index_id), _, _ ->
    let targets =
      targets
      |> List.filter (fun target -> target.target_generator.it <> index_id.it)
    in
    (match body.it, targets with
    | IfPr ({ it = CmpE (`EqOp, _, _left, _right); _ }), [ target ] ->
      (match
         lower_indexed_listn_target
           names
           ~lower_body
           ctx
           env
           ~bound_vars
           origin
           ~prem
           ~body
           generators
           count_exp
           index_id
           target
       with
      | Some result -> Some result
      | None ->
        Some
          ( Premise_diagnostic.unsupported_prem
              ctx
              env
              ~bound_vars
              origin
              "Premise/IterPr/ListNBindingMap"
              prem
              "indexed ListN binding-map shape was detected, but the body equality could not be lowered to a source-local binding-map helper"
          , names ))
    | IfPr ({ it = CmpE (`EqOp, _, _, _); _ }), [] ->
      Some
        ( Premise_diagnostic.unsupported_prem
            ctx
            env
            ~bound_vars
            origin
            "Premise/IterPr/ListNBindingMap"
            prem
            "indexed ListN binding-map premise has no unbound output sequence target after ignoring the index generator"
        , names )
    | IfPr ({ it = CmpE (`EqOp, _, _, _); _ }), _ :: _ :: _ ->
      Some
        ( Premise_diagnostic.unsupported_prem
            ctx
            env
            ~bound_vars
            origin
            "Premise/IterPr/ListNBindingMap"
            prem
            "indexed ListN binding-map premise has more than one unbound output sequence target"
        , names )
    | _ -> None)
  | List, IfPr ({ it = CmpE (`EqOp, _, left, right); _ }), [ target ] ->
    lower_list_target
      names
      ~lower_body
      ctx
      env
      ~bound_vars
      origin
      ~prem
      ~body
      generators
      left
      right
      target
  | List, IfPr ({ it = CmpE (`EqOp, _, _, _); _ }), _ :: _ :: _ ->
    lower_multi_list_targets
      names ~lower_body ctx env ~bound_vars origin ~prem ~body generators targets
  | _ -> None
