open Il.Ast
open Maude_ir
open Util.Source

open Expr_diagnostic
open Expr_env
open Expr_result

let s = sort
let spectec_terminals = s "SpectecTerminals"

let app name args = App (name, args)

let len term =
  app "len" [ term ]

let is_opt term =
  app "isOpt" [ term ]

let all_opt term =
  app "allOpt" [ term ]

type env = Expr_env.t

module Request = Helper_request

type callbacks =
  { lower_value : Context.t -> env -> Origin.t -> exp -> result
  ; lower_sequence : Context.t -> env -> Origin.t -> exp -> result
  }

type source_descriptor =
  { source_item_shape : Request.iter_map_source_item_shape
  ; source_element_typ : typ
  ; source_is_optional : bool
  ; source_listn_count : exp option
  }

type zip_source =
  { zip_id : id
  ; zip_source_exp : exp
  ; zip_element_typ : typ
  ; zip_element_sort : sort
  ; zip_source_item_shape : Request.iter_map_source_item_shape
  ; zip_source_listn_count : exp option
  ; zip_head_var : string
  ; zip_tail_var : string
  ; zip_source_shape : Request.iter_zip_source_shape
  }

let flat_list_element_typ typ =
  match typ.it with
  | IterT (element_typ, List) when not (Type_shape.typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let flat_optional_element_typ typ =
  match typ.it with
  | IterT (element_typ, Opt) when not (Type_shape.typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let nested_list_inner_typ typ =
  match typ.it with
  | IterT (({ it = IterT (element_typ, List); _ } as inner_list_typ), List)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some inner_list_typ
  | _ -> None

let optional_list_inner_typ typ =
  match typ.it with
  | IterT (({ it = IterT (element_typ, Opt); _ } as inner_optional_typ), List)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some inner_optional_typ
  | _ -> None

let optional_nested_list_inner_typ typ =
  match typ.it with
  | IterT (({ it = IterT (element_typ, List); _ } as inner_list_typ), Opt)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some inner_list_typ
  | _ -> None

let output_descriptor typ =
  match flat_list_element_typ typ with
  | Some element_typ -> Some (Request.Output_flat_terminal, element_typ)
  | None ->
    (match flat_optional_element_typ typ with
    | Some element_typ -> Some (Request.Output_flat_terminal, element_typ)
    | None ->
      (match nested_list_inner_typ typ with
      | Some inner_typ -> Some (Request.Output_nested_seq, inner_typ)
      | None ->
        (match optional_list_inner_typ typ with
        | Some inner_typ -> Some (Request.Output_nested_seq, inner_typ)
        | None ->
          (match optional_nested_list_inner_typ typ with
          | Some inner_typ -> Some (Request.Output_nested_seq, inner_typ)
          | None -> None))))

let current_bound_vars env =
  match Expr_env.condition_bound_vars env with
  | Some bound_vars -> bound_vars
  | None -> Expr_env.bound_vars env

let helper_call_missing_after_conditions ctx bound guards helper_args =
  match
    Condition_closure.conditions_admissible_bound
      ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
      bound guards
  with
  | None -> None
  | Some bound_after ->
    helper_args
    |> List.concat_map Condition_closure.term_vars
    |> List.sort_uniq String.compare
    |> List.filter (fun var -> not (List.mem var bound_after))
    |> fun vars -> Some vars

let premise_admissibility_reason ctx fallback bound guards helper_args =
  match helper_call_missing_after_conditions ctx bound guards helper_args with
  | None -> fallback ^ "; one of the helper argument guards is itself inadmissible"
  | Some [] -> fallback
  | Some missing ->
    fallback ^ "; missing helper argument variable(s): "
    ^ String.concat ", " missing

let source_descriptor_of_exp source_exp =
  match source_exp.note.it with
  | IterT (source_element_typ, List)
    when not (Type_shape.typ_is_iter source_element_typ) ->
    Some
      { source_item_shape = Request.Source_flat_terminal
      ; source_element_typ
      ; source_is_optional = false
      ; source_listn_count = None
      }
  | IterT (source_element_typ, Opt)
    when not (Type_shape.typ_is_iter source_element_typ) ->
    Some
      { source_item_shape = Request.Source_flat_terminal
      ; source_element_typ
      ; source_is_optional = true
      ; source_listn_count = None
      }
  | IterT (source_element_typ, ListN (count_exp, _))
    when not (Type_shape.typ_is_iter source_element_typ) ->
    Some
      { source_item_shape = Request.Source_flat_terminal
      ; source_element_typ
      ; source_is_optional = false
      ; source_listn_count = Some count_exp
      }
  | IterT (({ it = IterT (element_typ, List); _ } as source_element_typ), List)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some
      { source_item_shape = Request.Source_nested_seq
      ; source_element_typ
      ; source_is_optional = false
      ; source_listn_count = None
      }
  | IterT (({ it = IterT (element_typ, ListN _); _ } as source_element_typ), List)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some
      { source_item_shape = Request.Source_nested_seq
      ; source_element_typ
      ; source_is_optional = false
      ; source_listn_count = None
      }
  | IterT (({ it = IterT (element_typ, List); _ } as source_element_typ), Opt)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some
      { source_item_shape = Request.Source_nested_seq
      ; source_element_typ
      ; source_is_optional = true
      ; source_listn_count = None
      }
  | IterT
      ( ({ it = IterT (element_typ, List); _ } as source_element_typ)
      , ListN (count_exp, _) )
    when not (Type_shape.typ_is_iter element_typ) ->
    Some
      { source_item_shape = Request.Source_nested_seq
      ; source_element_typ
      ; source_is_optional = false
      ; source_listn_count = Some count_exp
      }
  | _ -> None

let source_element_carrier_sort typ =
  match typ.it with
  | IterT (element_typ, ListN _)
    when not (Type_shape.typ_is_iter element_typ) ->
    Some spectec_terminals
  | _ -> Carrier_sort.for_expression typ

let all_len term n =
  app "allLen" [ term; n ]

let listn_body_over_outer outer_id exp =
  match exp.it with
  | IterE ({ it = VarE body_id; _ }, (ListN (n_exp, _), [ generator_id, source_exp ]))
    when body_id.it = generator_id.it ->
    (match source_exp.it with
    | VarE source_id when source_id.it = outer_id -> Some n_exp
    | _ -> None)
  | _ -> None

let rec lower_iter callbacks ctx env origin exp body (iter, generators) =
  match iter, generators, body.it with
  | List, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it
         && Type_shape.is_optional_list_typ exp.note ->
    lower_optional_list_identity callbacks ctx env origin source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_optional_list_typ exp.note
         && is_identity_optional_expr_over callbacks generator_id.it body ->
    lower_optional_list_identity callbacks ctx env origin source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_nested_list_typ exp.note
         && is_lifted_identity_optional_expr_over callbacks generator_id.it body ->
    lower_optional_list_identity callbacks ctx env origin source_exp
  | List, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    callbacks.lower_sequence ctx env origin source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_nested_list_typ exp.note
         && is_identity_list_expr_over callbacks generator_id.it body ->
    callbacks.lower_sequence ctx env origin source_exp
  | List, [ generator_id, source_exp ], _
    when Type_shape.is_nested_list_typ exp.note ->
    (match listn_body_over_outer generator_id.it body with
    | Some n_exp ->
      lower_nested_outer_identity_listn callbacks ctx env origin exp source_exp n_exp
    | None ->
      lower_list_map_helper callbacks ctx env origin exp generator_id source_exp body)
  | ListN (n_exp, None), [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_flat_identity_listn callbacks ctx env origin exp source_exp n_exp
  | ListN (n_exp, None), [ generator_id, source_exp ], _ ->
    lower_listn_map_helper callbacks ctx env origin exp n_exp generator_id source_exp body
  | ListN (n_exp, None), [], _ ->
    lower_listn_repeat_helper callbacks ctx env origin exp n_exp body
  | ListN (n_exp, None), _ :: _ :: _, _ ->
    lower_listn_zip_map_helper callbacks ctx env origin exp n_exp body generators
  | ListN (n_exp, Some index_id), generators, _ ->
    lower_listn_helper callbacks ctx env origin exp n_exp (Some index_id) generators body
  | Opt, [ generator_id, source_exp ], VarE body_id
    when body_id.it = generator_id.it ->
    lower_flat_identity_opt callbacks ctx env origin source_exp
  | Opt, [ generator_id, source_exp ], _ ->
    lower_list_map_helper callbacks ctx env origin exp generator_id source_exp body
  | (Opt | List1), _, _ ->
    unsupported_exp ctx origin "Expr/IterE" exp
      "Opt/List1 IterE lowering requires helper semantics and is outside this sequence slice"
  | List, [ generator_id, source_exp ], _ ->
    lower_list_map_helper callbacks ctx env origin exp generator_id source_exp body
  | List, generators, _ when List.length generators >= 2 ->
    lower_list_zip_map_helper callbacks ctx env origin exp body generators
  | List, _, _ ->
    unsupported_exp ctx origin "Expr/IterE" exp
      "zip-map List iteration with multiple generators is not implemented in this helper slice"

and lower_listn_count callbacks ctx env origin exp n_exp =
  let count_result = callbacks.lower_value ctx env origin n_exp in
  let nat_sort_opt =
    match Carrier_sort.for_expression n_exp.note with
    | Some sort when Carrier_sort.is_nat_sort sort -> Some sort
    | _ ->
      (match Carrier_sort.primitive_numeric_alias_sort ctx n_exp.note with
      | Some sort when Carrier_sort.is_nat_sort sort -> Some sort
      | _ -> None)
  in
  match count_result.term, nat_sort_opt with
  | Some _, Some _ -> count_result
  | Some _, None ->
    { count_result with
      term = None
    ; diagnostics =
        count_result.diagnostics
        @ [ unsupported
              ~ctx ~origin ~constructor:"Expr/IterE/ListN/count"
              ~source_echo:(source_echo_exp exp)
              ~reason:
                "ListN helper count expression lowered, but its source note is not known to be Nat"
              ~suggestion:
                "Keep this ListN IterE Unsupported until the count can be represented as a Nat recursion argument"
              ()
          ]
    }
    | None, _ -> count_result

and source_listn_count_metadata callbacks ctx env origin exp source_term source_listn_count =
  match source_listn_count with
  | None -> true, [], []
  | Some count_exp ->
    let count_result = lower_listn_count callbacks ctx env origin exp count_exp in
    (match count_result.term with
    | Some count_term ->
      true,
      count_result.guards @ [ EqCond (len source_term, count_term) ],
      count_result.diagnostics
    | None -> false, count_result.guards, count_result.diagnostics)

and listn_source_length_guard _callbacks env source_term count_term =
  let bound_vars = current_bound_vars env in
  let source_vars = Condition_closure.term_vars source_term in
  let count_vars = Condition_closure.term_vars count_term in
  if Condition_closure.vars_subset count_vars bound_vars then
    EqCond (len source_term, count_term)
  else
    match count_term with
    | Var _ when Condition_closure.vars_subset source_vars bound_vars ->
      MatchCond (count_term, len source_term)
    | _ -> EqCond (len source_term, count_term)

and source_term_is_bound _callbacks env source_guards count_guards source_term =
  let bound =
    Condition_closure.conditions_bound_vars
      (current_bound_vars env)
      (source_guards @ count_guards)
  in
  Condition_closure.vars_subset
    (Condition_closure.term_vars source_term) bound

and lower_listn_map_helper callbacks ctx env origin exp n_exp generator_id source_exp body =
  let mapped = lower_list_map_helper callbacks ctx env origin exp generator_id source_exp body in
  let count_result = lower_listn_count callbacks ctx env origin exp n_exp in
  let source_result = callbacks.lower_sequence ctx env origin source_exp in
  match mapped.term, count_result.term, source_result.term with
  | Some _, Some count_term, Some source_term ->
    { mapped with
      guards =
        mapped.guards @ count_result.guards
        @ [ EqCond (len source_term, count_term) ]
    ; diagnostics = mapped.diagnostics @ count_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = mapped.guards @ count_result.guards @ source_result.guards
    ; diagnostics =
        mapped.diagnostics @ count_result.diagnostics @ source_result.diagnostics
    }

and lower_listn_zip_map_helper callbacks ctx env origin exp n_exp body generators =
  let count_result = lower_listn_count callbacks ctx env origin exp n_exp in
  match generators with
  | (_, source_exp) :: _ ->
    let source_result = callbacks.lower_sequence ctx env origin source_exp in
    (match count_result.term, source_result.term with
    | Some count_term, Some source_term ->
      let mapped = lower_list_zip_map_helper callbacks ctx env origin exp body generators in
      (match mapped.term with
      | Some _ ->
      { mapped with
        guards =
          mapped.guards @ count_result.guards
          @ [ listn_source_length_guard callbacks env source_term count_term ]
      ; diagnostics = mapped.diagnostics @ count_result.diagnostics
      }
      | None ->
        { term = None
        ; guards = mapped.guards @ count_result.guards @ source_result.guards
        ; diagnostics =
            mapped.diagnostics @ count_result.diagnostics @ source_result.diagnostics
        })
    | _ ->
      { term = None
      ; guards = count_result.guards @ source_result.guards
      ; diagnostics = count_result.diagnostics @ source_result.diagnostics
      })
  | [] -> lower_list_zip_map_helper callbacks ctx env origin exp body generators

and lower_source_consuming_listn_helper callbacks
    ?premise_bound_vars ctx env origin exp n_exp index_id generator_id source_exp body =
  let unsupported_source_listn reason =
    unsupported
      ~ctx ~origin ~constructor:"Expr/IterE/ListN/source-consuming"
      ~source_echo:(source_echo_exp exp)
      ~reason
      ~suggestion:
        "Keep this source-consuming indexed ListN Unsupported until the helper can preserve count, index, source head/tail, and body scope"
      ()
  in
  if index_id.it = generator_id.it then
    lower_listn_helper callbacks ctx env origin exp n_exp (Some index_id) [] body
  else
  let output_descriptor = output_descriptor exp.note in
    let source_descriptor = source_descriptor_of_exp source_exp in
    match output_descriptor, source_descriptor, Carrier_sort.for_expression body.note with
    | None, _, _ ->
      with_diagnostics
        [ unsupported_source_listn
            "source-consuming ListN helper requires the IterE output note to be a flat List or boundary-preserving nested List carrier"
        ]
    | _, None, _ ->
      with_diagnostics
        [ unsupported_source_listn
            ("source-consuming ListN helper requires a flat or boundary-preserving nested sequence source; source_note="
             ^ Il.Print.string_of_typ source_exp.note)
        ]
    | _, _, None ->
      with_diagnostics
        [ unsupported_source_listn
            "source-consuming ListN helper could not determine a carrier for the body expression"
        ]
    | Some (Request.Output_flat_terminal, _), Some _, Some body_sort
      when Carrier_sort.is_sequence_sort body_sort ->
      with_diagnostics
        [ unsupported_source_listn
            "source-consuming ListN helper refuses a sequence-valued body because that would flatten or erase nested output structure"
        ]
    | Some (Request.Output_nested_seq, _), Some _, Some body_sort
      when not (Carrier_sort.is_sequence_sort body_sort) ->
      with_diagnostics
        [ unsupported_source_listn
            "nested output ListN helper requires the body expression to lower to a sequence so the result can be wrapped as one outer element"
        ]
    | Some (output_item_shape, _), Some source_descriptor, Some body_sort ->
      if source_descriptor.source_is_optional then
        with_diagnostics
          [ unsupported_source_listn
              "source-consuming indexed ListN does not consume optional sources in this slice; the source must expose a deterministic head/tail sequence"
          ]
      else
        match source_element_carrier_sort source_descriptor.source_element_typ with
        | None ->
          with_diagnostics
            [ unsupported_source_listn
                "source-consuming ListN helper could not determine a carrier for the source element type"
            ]
        | Some source_element_sort ->
          let count_result = lower_listn_count callbacks ctx env origin exp n_exp in
          let source_result = callbacks.lower_sequence ctx env origin source_exp in
          (match count_result.term, source_result.term with
          | Some count_term, Some source_term ->
            if
              not
                (source_term_is_bound
                   callbacks
                   env
                   source_result.guards
                   count_result.guards
                   source_term)
            then
              lower_listn_helper callbacks ctx env origin exp n_exp (Some index_id) [] body
            else
            let source_listn_ok, source_listn_guards, source_listn_diagnostics =
              source_listn_count_metadata callbacks ctx env origin exp source_term source_descriptor.source_listn_count
            in
            if not source_listn_ok then
              { term = None
              ; guards =
                  source_result.guards @ count_result.guards @ source_listn_guards
              ; diagnostics =
                  source_result.diagnostics @ count_result.diagnostics
                  @ source_listn_diagnostics
              }
            else
              let local_source_ids =
                [ index_id.it; generator_id.it ]
                |> List.sort_uniq String.compare
              in
              let source_ids =
                Source_free_vars.exp_and_note_ids body
                @ Source_free_vars.exp_and_note_ids n_exp
                @ Source_free_vars.exp_and_note_ids source_exp
                @ Source_free_vars.type_note_ids exp.note
                |> List.sort_uniq String.compare
                |> List.filter (fun id ->
                  not (List.exists (( = ) id) local_source_ids))
              in
              let names =
                Local_name.reserve_sources
                  Local_name.empty (local_source_ids @ source_ids)
              in
              let count_var, names =
                Local_name.fresh_qualified_name
                  names Local_name.Count (sort_ref (s "Nat"))
              in
              let index_var =
                Local_name.source_qualified_name
                  names index_id.it (sort_ref (s "Nat"))
              in
              let helper_head_var =
                Local_name.source_qualified_name
                  names generator_id.it (sort_ref source_element_sort)
              in
              let source_tail_var, names =
                Local_name.fresh_qualified_name
                  names Local_name.Tail (sort_ref (s "SpectecTerminals"))
              in
              let body_result_var, _ =
                Local_name.fresh_qualified_name
                  names Local_name.Output (sort_ref body_sort)
              in
              let caller_guards =
                source_result.guards @ count_result.guards @ source_listn_guards
                @ [ listn_source_length_guard callbacks env source_term count_term ]
              in
              let index_binding =
                { term = Var index_var
                ; sort = s "Nat"
                ; typ = NumT `NatT $ index_id.at
                }
              in
              let generator_binding =
                { term = Var helper_head_var
                ; sort = source_element_sort
                ; typ = source_descriptor.source_element_typ
                }
              in
              let preliminary_body_env =
                env
                |> fun body_env -> Expr_env.add body_env generator_id.it generator_binding
                |> fun body_env -> Expr_env.add body_env index_id.it index_binding
              in
              let preliminary_body_result =
                callbacks.lower_value ctx preliminary_body_env origin body
              in
              (match preliminary_body_result.term with
              | None ->
                { term = None
                ; guards = caller_guards
                ; diagnostics =
                    source_result.diagnostics @ count_result.diagnostics
                    @ source_listn_diagnostics
                    @ preliminary_body_result.diagnostics
                }
              | Some preliminary_body ->
                let helper_local_vars =
                  [ count_var; index_var; helper_head_var; source_tail_var; body_result_var ]
                in
                let required_vars =
                  Condition_closure.external_vars_of_term_after_conditions
                    helper_local_vars
                    preliminary_body
                    preliminary_body_result.guards
                in
                let capture_candidates =
                  Helper_capture.required_capture_candidates env ~required_vars source_ids
                in
                let captured_vars =
                  Helper_capture.captured_vars capture_candidates
                in
                let missing_required_vars =
                  Helper_capture.missing_required_vars ~required_vars ~captured_vars
                in
                let missing_required_diagnostics =
                  missing_required_vars
                  |> List.map (fun var_name ->
                    unsupported
                      ~ctx ~origin ~constructor:"Expr/IterE/ListN/source-capture"
                      ~source_echo:(source_echo_exp exp)
                      ~reason:
                        ("source-consuming ListN body has free Maude variable `"
                         ^ var_name
                         ^ "`, but no required source variable maps to it as a plain capture")
                      ~suggestion:
                        "Keep this ListN Unsupported until the free variable can be represented by an explicit source binding"
                      ())
                in
                if missing_required_diagnostics <> [] then
                  { term = None
                  ; guards = caller_guards
                  ; diagnostics =
                      source_result.diagnostics @ count_result.diagnostics
                      @ source_listn_diagnostics @ preliminary_body_result.diagnostics
                      @ missing_required_diagnostics
                  }
                else
                  let captures =
                    Helper_capture.make_required_captures names capture_candidates
                  in
                  let helper_env =
                    Helper_capture.capture_env captures
                    |> fun helper_env ->
                    Expr_env.add helper_env generator_id.it generator_binding
                    |> fun helper_env ->
                    Expr_env.add helper_env index_id.it index_binding
                  in
                  let body_result = callbacks.lower_value ctx helper_env origin body in
                  let body_vars =
                    match body_result.term with
                    | Some term ->
                      Condition_closure.external_vars_of_term_after_conditions
                        helper_local_vars
                        term
                        body_result.guards
                    | None -> []
                  in
                  let captures =
                    captures
                    |> List.filter (fun capture ->
                      List.exists (( = ) capture.Request.formal_var) body_vars)
                  in
                  let allowed_body_vars =
                    [ index_var; helper_head_var ]
                    @ List.map (fun capture -> capture.Request.formal_var) captures
                  in
                  let variable_diagnostics =
                    if Condition_closure.vars_subset body_vars allowed_body_vars then
                      []
                    else
                      [ unsupported
                          ~ctx ~origin
                          ~constructor:"Expr/IterE/ListN/source-body-scope"
                          ~source_echo:(source_echo_exp exp)
                          ~reason:
                            "source-consuming ListN body references variables outside helper-local index, source head, and captured closure variables"
                          ~suggestion:
                            "Keep this ListN Unsupported until the helper can declare and sort those body-local variables source-safely"
                          ()
                      ]
                  in
                  (match body_result.term, variable_diagnostics with
                  | Some lowered_body, [] ->
                    let helper_request =
                      { Request.kind =
                          Request.Iter_listn_source
                            { source_shape =
                                { iter_source = source_echo_exp exp
                                ; body_source = source_echo_exp body
                                ; source_source = source_echo_exp source_exp
                                ; count_source = source_echo_exp n_exp
                                ; count_typ_source = Il.Print.string_of_typ n_exp.note
                                ; output_typ_source = Il.Print.string_of_typ exp.note
                                ; source_typ_source = Il.Print.string_of_typ source_exp.note
                                }
                            ; count_var
                            ; index_var
                            ; generator_var = generator_id.it
                            ; helper_head_var
                            ; source_tail_var
                            ; body_result_var
                            ; source_item_shape = source_descriptor.source_item_shape
                            ; output_item_shape
                            ; source_element_sort
                            ; captures
                            ; lowered_body
                            ; body_eq_conditions = body_result.guards
                            }
                      ; reason =
                          "single-generator source-consuming indexed ListN IterE helper"
                      ; origin
                      }
                    in
                    let helper_args =
                      count_term :: Const "0" :: source_term
                      :: List.map
                           (fun capture -> capture.Request.call_term)
                           captures
                    in
                    let premise_admissible =
                      match premise_bound_vars with
                      | None -> true
                      | Some bound ->
                        Condition_closure.helper_call_admissible_after_conditions
                          ~constructor_op:
                            (Condition_closure.source_constructor_certificate ctx)
                          bound
                          caller_guards
                          helper_args
                    in
                if not premise_admissible then
                  let reason =
                    match premise_bound_vars with
                    | None ->
                      "premise-local source-consuming ListN helper call would use variables that are not bound by the enclosing lhs or earlier admissible premise conditions"
                    | Some bound ->
                      premise_admissibility_reason
                        ctx
                        "premise-local source-consuming ListN helper call would use variables that are not bound by the enclosing lhs or earlier admissible premise conditions"
                        bound
                        caller_guards
                        helper_args
                  in
                  { term = None
                  ; guards = caller_guards
                  ; diagnostics =
                      source_result.diagnostics @ count_result.diagnostics
                      @ source_listn_diagnostics @ body_result.diagnostics
                          @ [ unsupported
                            ~ctx ~origin
                            ~constructor:"Expr/IterE/ListN/premise-admissibility"
                            ~deferral:Diagnostics.ListN_premise_admissibility
                            ~source_echo:(source_echo_exp exp)
                            ~reason
                            ~suggestion:
                              "Keep this premise ListN Unsupported until the count, source, and captures can be proven bound before the helper call"
                            ()
                        ]
                      }
                    else
                    let helper_name =
                      Helper.request (Context.helpers ctx) helper_request
                    in
                    { term =
                        Some
                          (app helper_name helper_args)
                    ; guards = caller_guards
                    ; diagnostics =
                        source_result.diagnostics @ count_result.diagnostics
                        @ source_listn_diagnostics @ body_result.diagnostics
                    }
                  | _ ->
                    { term = None
                    ; guards = caller_guards
                    ; diagnostics =
                        source_result.diagnostics @ count_result.diagnostics
                        @ source_listn_diagnostics @ body_result.diagnostics
                        @ variable_diagnostics
                    }))
          | _ ->
            { term = None
            ; guards = source_result.guards @ count_result.guards
            ; diagnostics = source_result.diagnostics @ count_result.diagnostics
            })

and lower_listn_helper callbacks ?premise_bound_vars ctx env origin exp n_exp index_id_opt generators body =
  let premise_bound_vars =
    match premise_bound_vars with
    | Some _ as bound_vars -> bound_vars
    | None -> Expr_env.condition_bound_vars env
  in
  let mode =
    match index_id_opt with
    | None -> Request.Repeat_count
    | Some _ -> Request.Indexed_from_zero
  in
  let unsupported_listn reason =
    unsupported
      ~ctx ~origin ~constructor:"Expr/IterE/ListN"
      ~source_echo:(source_echo_exp exp)
      ~reason
      ~suggestion:
        "Keep this ListN IterE Unsupported until the terminal-body repeat/index helper shape covers it"
      ()
  in
  match index_id_opt, generators with
  | Some index_id, [ generator_id, source_exp ] ->
    lower_source_consuming_listn_helper
      ?premise_bound_vars
      callbacks ctx env origin exp n_exp index_id generator_id source_exp body
  | _, _ when generators <> [] ->
    with_diagnostics
      [ unsupported_listn
          (Printf.sprintf
             "indexed ListN with generator source(s) needs premise/DecD binding closure before a source-consuming helper can be emitted soundly; generators=%d"
             (List.length generators))
      ]
  | _ ->
  match output_descriptor exp.note, Carrier_sort.for_expression body.note with
  | None, _ ->
    with_diagnostics
      [ unsupported_listn
          "ListN helper lowering is supported only when the IterE output note is a flat List or boundary-preserving nested List carrier"
      ]
  | _, None ->
    with_diagnostics
      [ unsupported_listn
          "ListN helper lowering could not determine a non-sequence carrier for the body expression"
      ]
  | Some (Request.Output_flat_terminal, _), Some body_sort
    when Carrier_sort.is_sequence_sort body_sort ->
    with_diagnostics
      [ unsupported_listn
          "ListN helper refuses a sequence-valued body because that would flatten or erase nested source structure"
      ]
  | Some (Request.Output_nested_seq, _), Some body_sort
    when not (Carrier_sort.is_sequence_sort body_sort) ->
    with_diagnostics
      [ unsupported_listn
          "nested-list ListN helper requires the body expression to lower to a sequence so the result can be wrapped as a single outer element"
      ]
  | Some (output_item_shape, _), Some body_sort ->
    let count_result = lower_listn_count callbacks ctx env origin exp n_exp in
    (match count_result.term with
    | None -> count_result
    | Some count_term ->
      let count_id_opt =
        match n_exp.it with
        | VarE count_id -> Some count_id
        | _ -> None
      in
      let generator_ids =
        generators |> List.map (fun (generator_id, _source_exp) -> generator_id.it)
      in
      let local_source_ids =
        Option.to_list (Option.map (fun id -> id.it) count_id_opt)
        @ Option.to_list (Option.map (fun id -> id.it) index_id_opt)
        @ generator_ids
      in
      let source_ids =
        Source_free_vars.exp_and_note_ids body
        @ Source_free_vars.exp_and_note_ids n_exp
        @ Source_free_vars.type_note_ids exp.note
        |> List.sort_uniq String.compare
        |> List.filter (fun id ->
          not (List.exists (( = ) id) local_source_ids))
      in
      let names =
        Local_name.reserve_sources
          Local_name.empty (local_source_ids @ source_ids)
      in
      let count_var, names =
        match count_id_opt with
        | Some count_id ->
          ( Local_name.source_qualified_name
              names count_id.it (sort_ref (s "Nat"))
          , names )
        | None ->
          Local_name.fresh_qualified_name
            names Local_name.Count (sort_ref (s "Nat"))
      in
      let count_binding_opt =
        match count_id_opt with
        | Some count_id ->
          Some
            ( count_id
            , { term = Var count_var
              ; sort = s "Nat"
              ; typ = n_exp.note
              } )
        | None -> None
      in
      let add_count_binding env =
        match count_binding_opt with
        | Some (count_id, binding) -> Expr_env.add env count_id.it binding
        | None -> env
      in
      let index_var_opt =
        index_id_opt
        |> Option.map (fun index_id ->
          Local_name.source_qualified_name
            names index_id.it (sort_ref (s "Nat")))
      in
      let body_result_var, _ =
        Local_name.fresh_qualified_name
          names Local_name.Output (sort_ref body_sort)
      in
      let source_guards = [] in
      let source_diagnostics = [] in
      let preliminary_body_env =
        let env = add_count_binding env in
        match index_id_opt, index_var_opt with
        | Some index_id, Some index_var ->
          Expr_env.add env index_id.it
            { term = Var index_var
            ; sort = s "Nat"
            ; typ = NumT `NatT $ index_id.at
            }
        | None, None -> env
        | Some _, None | None, Some _ -> env
      in
      let preliminary_body_result =
        callbacks.lower_value ctx preliminary_body_env origin body
      in
      (match preliminary_body_result.term with
      | None ->
        { term = None
        ; guards = count_result.guards @ source_guards
        ; diagnostics =
            count_result.diagnostics @ source_diagnostics
            @ preliminary_body_result.diagnostics
        }
      | Some preliminary_body ->
        let helper_local_vars =
          count_var :: body_result_var :: Option.to_list index_var_opt
        in
        let body_required_vars =
          Condition_closure.external_vars_of_term_after_conditions
            helper_local_vars
            preliminary_body
            preliminary_body_result.guards
        in
        let count_guard_required_vars =
          Condition_closure.external_vars_of_conditions [] count_result.guards
        in
        let required_vars =
          body_required_vars @ count_guard_required_vars
          |> List.sort_uniq String.compare
        in
        let capture_candidates =
          Helper_capture.required_capture_candidates env ~required_vars source_ids
        in
        let captured_vars =
          Helper_capture.captured_vars capture_candidates
        in
        let missing_required_vars =
          Helper_capture.missing_required_vars ~required_vars ~captured_vars
        in
        let missing_required_diagnostics =
          missing_required_vars
          |> List.map (fun var_name ->
            unsupported
              ~ctx ~origin ~constructor:"Expr/IterE/ListN/capture"
              ~source_echo:(source_echo_exp exp)
              ~reason:
                ("ListN helper lowered body or count guard has free Maude variable `"
                 ^ var_name
                 ^ "`, but no required source variable maps to it as a plain capture")
              ~suggestion:
                "Keep this ListN IterE Unsupported until the free variable can be represented by an explicit source binding"
              ())
        in
        if missing_required_diagnostics <> [] then
          { term = None
          ; guards = count_result.guards @ source_guards
          ; diagnostics =
              count_result.diagnostics @ source_diagnostics
              @ preliminary_body_result.diagnostics
              @ missing_required_diagnostics
          }
        else
          let captures =
            Helper_capture.make_required_captures names capture_candidates
          in
          let helper_env =
            let captured_env = Helper_capture.capture_env captures in
            let captured_env = add_count_binding captured_env in
            match index_id_opt, index_var_opt with
            | Some index_id, Some index_var ->
              Expr_env.add captured_env index_id.it
                { term = Var index_var
                ; sort = s "Nat"
                ; typ = NumT `NatT $ index_id.at
                }
            | None, None -> captured_env
            | Some _, None | None, Some _ -> captured_env
          in
          let body_result = callbacks.lower_value ctx helper_env origin body in
          let body_vars =
            match body_result.term with
            | Some term ->
              Condition_closure.external_vars_of_term_after_conditions
                helper_local_vars
                term
                body_result.guards
            | None -> []
          in
          let allowed_body_vars =
            Option.to_list index_var_opt
            @ List.map (fun capture -> capture.Request.formal_var) captures
          in
          let variable_diagnostics =
            if Condition_closure.vars_subset body_vars allowed_body_vars then
              []
            else
              [ unsupported
                  ~ctx ~origin ~constructor:"Expr/IterE/ListN/body-scope"
                  ~source_echo:(source_echo_exp exp)
                  ~reason:
                    "ListN helper body introduces or references variables outside the helper-local index and captured closure variables"
                  ~suggestion:
                    "Keep this ListN IterE Unsupported until the helper can declare and sort those body-local variables source-safely"
                  ()
              ]
          in
          (match body_result.term, variable_diagnostics with
          | Some lowered_body, [] ->
            let capture_terms =
              List.map (fun capture -> capture.Request.call_term) captures
            in
            let helper_args =
              match index_var_opt with
              | None -> count_term :: capture_terms
              | Some _ -> count_term :: Const "0" :: capture_terms
            in
            let caller_guards = count_result.guards @ source_guards in
            let premise_admissible =
              match premise_bound_vars with
              | None -> true
              | Some bound ->
                Condition_closure.helper_call_admissible_after_conditions
                  ~constructor_op:
                    (Condition_closure.source_constructor_certificate ctx)
                  bound
                  caller_guards
                  helper_args
            in
            if not premise_admissible then
              let reason =
                match premise_bound_vars with
                | None ->
                  "premise-local ListN helper call would use variables that are not bound by the enclosing lhs or earlier admissible premise conditions"
                | Some bound ->
                  premise_admissibility_reason
                    ctx
                    "premise-local ListN helper call would use variables that are not bound by the enclosing lhs or earlier admissible premise conditions"
                    bound
                    caller_guards
                    helper_args
              in
              { term = None
              ; guards = caller_guards
              ; diagnostics =
                  count_result.diagnostics @ source_diagnostics
                  @ body_result.diagnostics
                  @ [ unsupported
                        ~ctx ~origin
                        ~constructor:"Expr/IterE/ListN/premise-admissibility"
                        ~deferral:Diagnostics.ListN_premise_admissibility
                        ~source_echo:(source_echo_exp exp)
                        ~reason
                        ~suggestion:
                          "Keep this premise ListN Unsupported until the count and captures can be proven bound before the helper call"
                        ()
                    ]
              }
            else
              let helper_request =
                { Request.kind =
                    Request.Iter_listn
                      { source_shape =
                          { iter_source = source_echo_exp exp
                          ; body_source = source_echo_exp body
                          ; count_source = source_echo_exp n_exp
                          ; count_typ_source = Il.Print.string_of_typ n_exp.note
                          ; output_typ_source = Il.Print.string_of_typ exp.note
                          ; mode
                          }
                      ; call_shape = Request.Count_then_captures
                      ; count_var
                      ; index_var = index_var_opt
                      ; body_result_var
                      ; output_item_shape
                      ; captures
                      ; lowered_body
                      ; body_eq_conditions = body_result.guards
                      }
                ; reason = "generic terminal-body ListN IterE helper"
                ; origin
                }
              in
              let helper_name =
                Helper.request (Context.helpers ctx) helper_request
              in
              { term = Some (app helper_name helper_args)
              ; guards = caller_guards
              ; diagnostics =
                  count_result.diagnostics @ source_diagnostics
                  @ body_result.diagnostics
              }
          | _ ->
            { term = None
            ; guards = count_result.guards @ source_guards
            ; diagnostics =
                count_result.diagnostics @ source_diagnostics
                @ body_result.diagnostics @ variable_diagnostics
            })))

and lower_listn_repeat_helper callbacks ctx env origin exp n_exp body =
  match Expr_env.condition_bound_vars env with
  | Some bound_vars ->
    lower_listn_helper
      ~premise_bound_vars:bound_vars
      callbacks ctx env origin exp n_exp None [] body
  | None -> lower_listn_helper callbacks ctx env origin exp n_exp None [] body

and lower_nested_outer_identity_listn callbacks ctx env origin exp source_exp n_exp =
  let source_result = callbacks.lower_sequence ctx env origin source_exp in
  let count_result = lower_listn_count callbacks ctx env origin exp n_exp in
  match source_result.term, count_result.term with
  | Some source_term, Some count_term ->
    { term = Some source_term
    ; guards =
        source_result.guards @ count_result.guards
        @ [ EqCond (all_len source_term count_term, Const "true") ]
    ; diagnostics = source_result.diagnostics @ count_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = source_result.guards @ count_result.guards
    ; diagnostics = source_result.diagnostics @ count_result.diagnostics
    }

and lower_list_map_helper callbacks ctx env origin exp generator_id source_exp body =
  let source_descriptor =
    source_descriptor_of_exp source_exp
  in
  let output_descriptor = output_descriptor exp.note in
  match output_descriptor, source_descriptor with
  | None, _ ->
    unsupported_exp ctx origin "Expr/IterE" exp
      "generic List/Opt map helper lowering is supported only when the IterE output note is a flat List/Opt, T?*, or boundary-preserving nested List carrier"
  | _, None ->
    unsupported_exp ctx origin "Expr/IterE" exp
      ("generic List/Opt map helper lowering requires the source expression note to be a flat List, flat Opt, or nested T** carrier with flat T* outer elements; source_note="
       ^ Il.Print.string_of_typ source_exp.note
       ^ "; output_note="
       ^ Il.Print.string_of_typ exp.note
       ^ "; body_note="
       ^ Il.Print.string_of_typ body.note)
  | Some (output_item_shape, _output_element_typ), Some source_descriptor ->
    let source_item_shape = source_descriptor.source_item_shape in
    let source_element_typ = source_descriptor.source_element_typ in
    let source_is_optional = source_descriptor.source_is_optional in
    let source_listn_count = source_descriptor.source_listn_count in
    (match
       source_element_carrier_sort source_element_typ,
       Carrier_sort.for_expression body.note
     with
    | None, _ ->
      unsupported_exp ctx origin "Expr/IterE" exp
        "generic List map helper lowering could not determine a carrier for the source element type"
    | _, None ->
      unsupported_exp ctx origin "Expr/IterE" exp
        "generic List map helper lowering could not determine a carrier for the body expression"
    | _, Some body_sort
      when output_item_shape = Request.Output_flat_terminal
           && Carrier_sort.is_sequence_sort body_sort ->
      unsupported_exp ctx origin "Expr/IterE" exp
        "generic List map helper refuses a sequence-valued body because that would flatten or erase nested source structure"
    | _, Some body_sort
      when output_item_shape = Request.Output_nested_seq
           && not (Carrier_sort.is_sequence_sort body_sort) ->
      unsupported_exp ctx origin "Expr/IterE" exp
        "nested-list IterE helper requires the body expression to lower to a sequence so the result can be wrapped as a single outer element"
    | Some source_element_sort, Some body_sort ->
      let body_source_ids =
        Source_free_vars.exp_and_note_ids body
        @ Source_free_vars.type_note_ids exp.note
        @ Source_free_vars.type_note_ids source_exp.note
        |> List.sort_uniq String.compare
        |> List.filter (fun id -> id <> generator_id.it)
      in
      let names =
        Local_name.reserve_sources
          Local_name.empty (generator_id.it :: body_source_ids)
      in
      let helper_head_var =
        Local_name.source_qualified_name
          names generator_id.it (sort_ref source_element_sort)
      in
      let source_tail_var, names =
        Local_name.fresh_qualified_name
          names Local_name.Tail (sort_ref (s "SpectecTerminals"))
      in
      let body_result_var, _ =
        Local_name.fresh_qualified_name
          names Local_name.Output (sort_ref body_sort)
      in
      let preliminary_body_env =
        Expr_env.add env generator_id.it
          { term = Var helper_head_var; sort = source_element_sort; typ = source_element_typ }
      in
      let preliminary_body_result =
        callbacks.lower_value ctx preliminary_body_env origin body
      in
      let source_result = callbacks.lower_sequence ctx env origin source_exp in
      match preliminary_body_result.term with
      | None ->
        { term = None
        ; guards = source_result.guards
        ; diagnostics =
            source_result.diagnostics @ preliminary_body_result.diagnostics
        }
      | Some preliminary_body ->
      let required_vars =
        Condition_closure.external_vars_of_term_after_conditions
          [ helper_head_var; source_tail_var; body_result_var ]
          preliminary_body
          preliminary_body_result.guards
      in
      let capture_candidates =
        Helper_capture.required_capture_candidates env ~required_vars body_source_ids
      in
      let captured_vars =
        Helper_capture.captured_vars capture_candidates
      in
      let missing_required_vars =
        Helper_capture.missing_required_vars ~required_vars ~captured_vars
      in
      let missing_required_diagnostics =
        missing_required_vars
        |> List.map (fun var_name ->
          unsupported
            ~ctx ~origin ~constructor:"Expr/IterE/capture"
            ~source_echo:(source_echo_exp exp)
            ~reason:
              ("generic List map helper lowered body has free Maude variable `"
               ^ var_name
               ^ "`, but no required body source variable maps to it as a plain capture")
            ~suggestion:
              "Keep this IterE Unsupported until the free variable can be represented by an explicit source binding"
            ())
      in
      if missing_required_diagnostics <> [] then
        { term = None
        ; guards = source_result.guards
        ; diagnostics =
            source_result.diagnostics @ preliminary_body_result.diagnostics
            @ missing_required_diagnostics
        }
      else
        let captures =
          Helper_capture.make_required_captures names capture_candidates
        in
        let helper_env =
          Helper_capture.capture_env captures
          |> fun helper_env ->
          Expr_env.add helper_env generator_id.it
            { term = Var helper_head_var
            ; sort = source_element_sort
            ; typ = source_element_typ
            }
        in
        let body_result = callbacks.lower_value ctx helper_env origin body in
        let body_vars =
          match body_result.term with
          | Some term ->
            Condition_closure.external_vars_of_term_after_conditions
              [ helper_head_var; source_tail_var; body_result_var ]
              term
              body_result.guards
          | None -> []
        in
        let captures =
          captures
          |> List.filter (fun capture ->
            List.exists (( = ) capture.Request.formal_var) body_vars)
        in
        let allowed_body_vars =
          helper_head_var :: List.map (fun capture -> capture.Request.formal_var) captures
        in
        let variable_diagnostics =
          if Condition_closure.vars_subset body_vars allowed_body_vars then
            []
          else
            [ unsupported
                ~ctx ~origin ~constructor:"Expr/IterE/body-scope"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  "generic List map helper body introduces or references variables outside the generator and captured closure variables"
                ~suggestion:
                  "Keep this IterE Unsupported until the helper can declare and sort those body-local variables source-safely"
                ()
            ]
        in
        let source_result = callbacks.lower_sequence ctx env origin source_exp in
        (match source_result.term, body_result.term, variable_diagnostics with
        | Some source_term, Some lowered_body, [] ->
          let source_listn_ok, source_listn_guards, source_listn_diagnostics =
            source_listn_count_metadata callbacks ctx env origin exp source_term source_listn_count
          in
          if not source_listn_ok then
            { term = None
            ; guards = source_result.guards @ source_listn_guards
            ; diagnostics =
                source_result.diagnostics @ body_result.diagnostics
                @ source_listn_diagnostics
            }
          else
          let source_guards =
            if source_is_optional then
              source_result.guards @ source_listn_guards
              @ [ EqCond (is_opt source_term, Const "true") ]
            else
              source_result.guards @ source_listn_guards
          in
          let helper_request =
            { Request.kind =
                Request.Iter_map
                  { source_shape =
                      { iter_source = source_echo_exp exp
                      ; body_source = source_echo_exp body
                      ; source_source = source_echo_exp source_exp
                      ; output_typ_source = Il.Print.string_of_typ exp.note
                      ; source_typ_source = Il.Print.string_of_typ source_exp.note
                      }
                  ; call_shape = Request.Source_then_captures
                  ; generator_var = generator_id.it
                  ; helper_head_var
                  ; source_tail_var
                    ; body_result_var
                    ; source_item_shape
                    ; output_item_shape
                    ; source_element_sort
                  ; captures
                  ; lowered_body
                  ; body_eq_conditions = body_result.guards
                  }
            ; reason = "generic single-generator List IterE map helper"
            ; origin
            }
          in
          let helper_name = Helper.request (Context.helpers ctx) helper_request in
          { term =
              Some
                (app helper_name
                   (source_term
                    :: List.map
                         (fun capture -> capture.Request.call_term)
                         captures))
          ; guards = source_guards
          ; diagnostics = source_result.diagnostics @ body_result.diagnostics
                          @ source_listn_diagnostics
          }
        | _ ->
          { term = None
          ; guards = source_result.guards
          ; diagnostics =
              source_result.diagnostics @ body_result.diagnostics
              @ variable_diagnostics
          }))

and lower_list_zip_map_helper callbacks ctx env origin exp body generators =
  let unsupported_zip reason =
    unsupported
      ~ctx ~origin ~constructor:"Expr/IterE/zip-map"
      ~source_echo:(source_echo_exp exp)
      ~reason
      ~suggestion:"Keep this zip-map IterE Unsupported until the generic lockstep helper shape covers it"
      ()
  in
  let output_descriptor = output_descriptor exp.note in
  match output_descriptor, Carrier_sort.for_expression body.note with
  | None, _ ->
    with_diagnostics
      [ unsupported_zip
          "generic List zip-map helper lowering is supported only when the IterE output note is a flat List or boundary-preserving nested List carrier"
      ]
  | _, None ->
    with_diagnostics
      [ unsupported_zip
          "generic List zip-map helper lowering could not determine a carrier for the body expression"
      ]
  | Some (Request.Output_flat_terminal, _), Some body_sort
    when Carrier_sort.is_sequence_sort body_sort ->
    with_diagnostics
      [ unsupported_zip
          "generic List zip-map helper refuses a sequence-valued body because that would flatten or erase nested source structure"
      ]
  | Some (Request.Output_nested_seq, _), Some body_sort
    when not (Carrier_sort.is_sequence_sort body_sort) ->
    with_diagnostics
      [ unsupported_zip
          "nested-list zip-map helper requires the body expression to lower to a sequence so the result can be wrapped as a single outer element"
      ]
  | Some (output_item_shape, _), Some body_sort ->
      let generator_ids =
        generators |> List.map (fun (generator_id, _) -> generator_id.it)
      in
      let body_source_ids =
        Source_free_vars.exp_ids body
        @ Source_free_vars.type_note_ids body.note
        @ Source_free_vars.type_note_ids exp.note
        @ (generators
           |> List.concat_map (fun (_, source_exp) ->
             Source_free_vars.type_note_ids source_exp.note))
        |> List.sort_uniq String.compare
        |> List.filter (fun id -> not (List.mem id generator_ids))
      in
      let names =
        Local_name.reserve_sources
          Local_name.empty (generator_ids @ body_source_ids)
      in
      let prepare_source names (generator_id, source_exp) =
        let source_descriptor = source_descriptor_of_exp source_exp in
        match source_descriptor with
        | None ->
          Error
            (unsupported_zip
               ("zip-map generator `" ^ generator_id.it
                ^ "` source is not a supported List carrier; expected flat T* or boundary-preserving nested T**"))
        | Some source_descriptor ->
          let source_item_shape = source_descriptor.source_item_shape in
          let element_typ = source_descriptor.source_element_typ in
          (match source_element_carrier_sort element_typ with
          | None ->
            Error
              (unsupported_zip
                 ("zip-map generator `" ^ generator_id.it
                  ^ "` has no safely known element carrier"))
          | Some element_sort ->
            let tail_var, names =
              Local_name.fresh_qualified_name
                names Local_name.Tail (sort_ref (s "SpectecTerminals"))
            in
            let source_shape : Request.iter_zip_source_shape =
              { Request.generator_source_id = generator_id.it
              ; source_source = source_echo_exp source_exp
              ; source_typ_source = Il.Print.string_of_typ source_exp.note
              }
            in
            Ok
              ( { zip_id = generator_id
                ; zip_source_exp = source_exp
                ; zip_element_typ = element_typ
                ; zip_element_sort = element_sort
                ; zip_source_item_shape = source_item_shape
                ; zip_source_listn_count = source_descriptor.source_listn_count
                ; zip_source_shape = source_shape
                ; zip_head_var =
                    Local_name.source_qualified_name
                      names generator_id.it (sort_ref element_sort)
                ; zip_tail_var = tail_var
                }
              , names ))
      in
      let rec prepare_sources names prepared = function
        | [] -> List.rev prepared, names
        | generator :: generators ->
          (match prepare_source names generator with
          | Error diagnostic ->
            prepare_sources names (Error diagnostic :: prepared) generators
          | Ok (source, names) ->
            prepare_sources names (Ok source :: prepared) generators)
      in
      let prepared, names = prepare_sources names [] generators in
      let body_result_var, _ =
        Local_name.fresh_qualified_name
          names Local_name.Output (sort_ref body_sort)
      in
      let source_shape_diagnostics =
        prepared
        |> List.filter_map (function
          | Ok _ -> None
          | Error diagnostic -> Some diagnostic)
      in
      if source_shape_diagnostics <> [] then
        with_diagnostics source_shape_diagnostics
      else
        let sources =
          prepared
          |> List.filter_map (function
            | Ok source -> Some source
            | Error _ -> None)
        in
        let source_results =
          sources
          |> List.map (fun source -> callbacks.lower_sequence ctx env origin source.zip_source_exp)
        in
        let source_guards, source_diagnostics = append_result_metadata source_results in
        let source_terms =
          source_results |> List.filter_map (fun result -> result.term)
        in
        if List.length source_terms <> List.length sources then
          { term = None; guards = source_guards; diagnostics = source_diagnostics }
        else
          let length_guards =
            match source_terms with
            | [] | [ _ ] -> []
            | first :: rest ->
              rest |> List.map (fun source_term -> EqCond (len source_term, len first))
          in
          let source_listn_metadata =
            List.map2
              (fun source source_term ->
                source_listn_count_metadata
                  callbacks
                  ctx
                  env
                  origin
                  exp
                  source_term
                  source.zip_source_listn_count)
              sources
              source_terms
          in
          let source_listn_ok =
            List.for_all (fun (ok, _, _) -> ok) source_listn_metadata
          in
          let source_listn_guards =
            source_listn_metadata
            |> List.map (fun (_, guards, _) -> guards)
            |> List.concat
          in
          let source_listn_diagnostics =
            source_listn_metadata
            |> List.map (fun (_, _, diagnostics) -> diagnostics)
            |> List.concat
          in
          let caller_guards =
            source_guards @ source_listn_guards @ length_guards
          in
          if not source_listn_ok then
            { term = None
            ; guards = caller_guards
            ; diagnostics = source_diagnostics @ source_listn_diagnostics
            }
          else
        let preliminary_body_env =
          sources
          |> List.fold_left
               (fun body_env source ->
                 Expr_env.add body_env source.zip_id.it
                   { term = Var source.zip_head_var
                   ; sort = source.zip_element_sort
                   ; typ = source.zip_element_typ
                   })
               env
        in
        let preliminary_body_result =
          callbacks.lower_value ctx preliminary_body_env origin body
        in
        (match preliminary_body_result.term with
        | None ->
          { term = None
          ; guards = caller_guards
          ; diagnostics =
              source_diagnostics @ source_listn_diagnostics
              @ preliminary_body_result.diagnostics
          }
        | Some preliminary_body ->
          let helper_head_vars =
            sources |> List.map (fun source -> source.zip_head_var)
          in
          let helper_tail_vars =
            sources |> List.map (fun source -> source.zip_tail_var)
          in
          let required_vars =
            Condition_closure.external_vars_of_term_after_conditions
              (helper_head_vars @ helper_tail_vars @ [ body_result_var ])
              preliminary_body
              preliminary_body_result.guards
          in
          let capture_candidates =
            Helper_capture.required_capture_candidates env ~required_vars body_source_ids
          in
          let captured_vars =
            Helper_capture.captured_vars capture_candidates
          in
          let missing_required_vars =
            Helper_capture.missing_required_vars ~required_vars ~captured_vars
          in
          let missing_required_diagnostics =
            missing_required_vars
            |> List.map (fun var_name ->
              unsupported
                ~ctx ~origin ~constructor:"Expr/IterE/zip-map/capture"
                ~source_echo:(source_echo_exp exp)
                ~reason:
                  ("generic List zip-map helper lowered body has free Maude variable `"
                   ^ var_name
                   ^ "`, but no required body source variable maps to it as a plain capture")
                ~suggestion:
                  "Keep this IterE Unsupported until the free variable can be represented by an explicit source binding"
                ())
          in
          if missing_required_diagnostics <> [] then
            { term = None
            ; guards = caller_guards
            ; diagnostics =
                source_diagnostics @ source_listn_diagnostics
                @ preliminary_body_result.diagnostics
                @ missing_required_diagnostics
            }
          else
            let captures =
              Helper_capture.make_required_captures names capture_candidates
            in
            let helper_env =
              let captured_env =
                Helper_capture.capture_env captures
              in
              sources
              |> List.fold_left
                   (fun helper_env source ->
                     Expr_env.add helper_env source.zip_id.it
                       { term = Var source.zip_head_var
                       ; sort = source.zip_element_sort
                       ; typ = source.zip_element_typ
                       })
                   captured_env
            in
            let body_result = callbacks.lower_value ctx helper_env origin body in
            let body_vars =
              match body_result.term with
              | Some term ->
                Condition_closure.external_vars_of_term_after_conditions
                  (helper_head_vars @ helper_tail_vars @ [ body_result_var ])
                  term
                  body_result.guards
              | None -> []
            in
            let captures =
              Helper_capture.filter_used_captures body_vars captures
            in
            let allowed_body_vars =
              helper_head_vars
              @ List.map (fun capture -> capture.Request.formal_var) captures
            in
            let variable_diagnostics =
              if Condition_closure.vars_subset body_vars allowed_body_vars then
                []
              else
                [ unsupported
                    ~ctx ~origin ~constructor:"Expr/IterE/zip-map/body-scope"
                    ~source_echo:(source_echo_exp exp)
                    ~reason:
                      "generic List zip-map helper body introduces or references variables outside generator heads and captured closure variables"
                    ~suggestion:
                      "Keep this IterE Unsupported until the helper can declare and sort those body-local variables source-safely"
                    ()
                ]
            in
            (match body_result.term, variable_diagnostics with
            | Some lowered_body, [] ->
              let helper_request =
                { Request.kind =
                    Request.Iter_zip_map
                      { source_shape =
                          { iter_source = source_echo_exp exp
                          ; body_source = source_echo_exp body
                          ; output_typ_source = Il.Print.string_of_typ exp.note
                          ; sources =
                              sources
                              |> List.map (fun source -> source.zip_source_shape)
                          }
                      ; call_shape = Request.Source_then_captures
                      ; sources =
                          sources
                          |> List.map (fun source ->
                            ({ Request.source_shape = source.zip_source_shape
                            ; source_item_shape = source.zip_source_item_shape
                            ; helper_head_var = source.zip_head_var
                            ; source_tail_var = source.zip_tail_var
                            ; source_element_sort = source.zip_element_sort
                            } : Request.iter_zip_source))
                      ; body_result_var
                      ; output_item_shape
                      ; captures
                      ; lowered_body
                      ; body_eq_conditions = body_result.guards
                      }
                ; reason = "generic multi-generator List IterE zip-map helper"
                ; origin
                }
              in
              let helper_name = Helper.request (Context.helpers ctx) helper_request in
              { term =
                  Some
                    (app helper_name
                       (source_terms
                        @ List.map
                            (fun capture -> capture.Request.call_term)
                            captures))
              ; guards = caller_guards
              ; diagnostics =
                  source_diagnostics @ source_listn_diagnostics
                  @ body_result.diagnostics
              }
            | _ ->
              { term = None
              ; guards = caller_guards
              ; diagnostics =
                  source_diagnostics @ source_listn_diagnostics
                  @ body_result.diagnostics @ variable_diagnostics
              }))

and lower_optional_list_identity callbacks ctx env origin source_exp =
  let source_result = callbacks.lower_sequence ctx env origin source_exp in
  match source_result.term with
  | Some source_term ->
    { term = Some source_term
    ; guards = source_result.guards @ [ EqCond (all_opt source_term, Const "true") ]
    ; diagnostics = source_result.diagnostics
    }
  | None -> source_result

and lower_flat_identity_opt callbacks ctx env origin source_exp =
  let source_result = callbacks.lower_sequence ctx env origin source_exp in
  match source_result.term with
  | Some source_term ->
    { term = Some source_term
    ; guards = source_result.guards @ [ EqCond (is_opt source_term, Const "true") ]
    ; diagnostics = source_result.diagnostics
    }
  | None -> source_result

and lower_flat_identity_listn callbacks ctx env origin exp source_exp n_exp =
  let source_result = callbacks.lower_sequence ctx env origin source_exp in
  let n_result = lower_listn_count callbacks ctx env origin exp n_exp in
  match source_result.term, n_result.term with
  | Some source_term, Some n_term ->
    let len_term = len source_term in
    let len_condition =
      match n_term with
      | Var _ -> MatchCond (n_term, len_term)
      | _ -> EqCond (len_term, n_term)
    in
    { term = Some source_term
    ; guards = source_result.guards @ n_result.guards @ [ len_condition ]
    ; diagnostics = source_result.diagnostics @ n_result.diagnostics
    }
  | _ ->
    { term = None
    ; guards = source_result.guards @ n_result.guards
    ; diagnostics = source_result.diagnostics @ n_result.diagnostics
    }

and is_identity_list_expr_over _callbacks outer_id exp =
  match exp.it with
  | VarE id -> id.it = outer_id
  | IterE ({ it = VarE body_id; _ }, (List, [ generator_id, source_exp ])) ->
    body_id.it = generator_id.it
    && (match source_exp.it with
      | VarE source_id -> source_id.it = outer_id
      | _ -> false)
  | _ -> false

and is_identity_optional_expr_over _callbacks outer_id exp =
  match exp.it with
  | IterE ({ it = VarE body_id; _ }, (Opt, [ generator_id, source_exp ]))
    when body_id.it = generator_id.it ->
    (match source_exp.it with
    | VarE source_id when source_id.it = outer_id -> true
    | _ -> false)
  | _ -> false

and is_lifted_identity_optional_expr_over callbacks outer_id exp =
  match exp.it with
  | LiftE inner -> is_identity_optional_expr_over callbacks outer_id inner
  | _ -> false
