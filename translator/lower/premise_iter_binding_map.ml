open Il.Ast
open Maude_ir
open Util.Source

open Premise_capture
open Premise_iter_support

type target =
  { target_generator : id
  ; target_source_id : id
  ; target_source_exp : exp
  ; target_source_term : term
  ; target_source_binding : Expr_translate.binding
  ; target_element_typ : typ
  ; target_element_sort : sort
  }

let rec is_direct_var_exp var exp =
  match exp.it with
  | VarE id -> id.it = var
  | OptE (Some inner) -> is_direct_var_exp var inner
  | _ -> false

let targets env ~bound_vars generators =
  generators
  |> List.filter_map (fun (target_generator, target_source_exp) ->
    match
      Premise_state.unbound_direct_var env ~bound_vars target_source_exp,
      flat_list_element_typ target_source_exp.note
    with
    | Some target_source_id, Some target_element_typ ->
      (match Expr_translate.carrier_sort_of_typ target_element_typ with
      | Some target_element_sort ->
        let source_binding =
          match Expr_translate.find_var env target_source_id.it with
          | Some binding -> Some (binding.term, binding)
          | None -> Premise_state.typed_var_for_exp target_source_id target_source_exp
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
    ~lower_body ctx env ~bound_vars origin ~prem ~body generators count_exp index_id target =
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
  let captures = body_source_ids |> capture_candidates env |> make_captures stem in
  let add_count_binding helper_env =
    match count_binding with
    | Some (count_id, binding) -> Expr_translate.add_var helper_env count_id binding
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
  let body_result = lower_body helper_env ~bound_vars:helper_bound origin body in
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
      Condition_closure.conditions_admissible_bound helper_bound helper_conditions
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
          let helper_name = Helper.request (Context.helpers ctx) helper_request in
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
            Condition_closure.external_vars_of_conditions bound_vars caller_conditions
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

let lower_list_target
    ~lower_body ctx env ~bound_vars origin ~prem ~body generators left right target =
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
              "_" ^ Naming.maude_var ~fallback:"GEN" source_generator.it
            in
            let helper_head_var = "HEAD" ^ stem ^ suffix in
            let source_tail_var = "TAIL" ^ stem ^ suffix in
            let body_result_var = "OUT" ^ stem in
            let generator_ids = generators |> List.map (fun (id, _) -> id.it) in
            let body_source_ids =
              prem_free_var_ids body
              |> List.filter (fun id -> not (List.mem id generator_ids))
              |> List.sort_uniq String.compare
            in
            let captures =
              body_source_ids |> capture_candidates env |> make_captures stem
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
            let helper_bound = helper_head_var :: capture_vars captures in
            let body_result =
              lower_body helper_env ~bound_vars:helper_bound origin body
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
              let captures = captures |> filter_used_captures body_used_vars in
              let helper_bound = helper_head_var :: capture_vars captures in
              let helper_bound_with_output = body_result_var :: helper_bound in
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
    | [] | _ :: _ :: _ -> None

let try_lower ~lower_body ctx env ~bound_vars origin ~prem ~body iter generators =
  let targets = targets env ~bound_vars generators in
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
    lower_list_target
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
  | _ -> None
