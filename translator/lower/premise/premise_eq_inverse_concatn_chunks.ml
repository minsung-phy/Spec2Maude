open Il.Ast
open Maude_ir
open Util.Source

module Request = Helper_request

open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_exp = Premise_diagnostic.source_echo_exp
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let with_conditions = Premise_state.with_conditions
let unbound_direct_var = Premise_state.unbound_direct_var
let typed_var_for_exp = Premise_state.typed_var_for_exp
let lower_with_source_carrier = Premise_shape.lower_with_source_carrier

let app name args =
  App (name, args)

let call_target_id ctx id =
  match Context.find_static_def ctx id.it with
  | Some target_id -> { id with it = target_id }
  | None -> id

let var_exp_id exp =
  match exp.it with
  | VarE id -> Some id
  | _ -> None

let exp_is_var id exp =
  match var_exp_id exp with
  | Some actual -> actual.it = id.it
  | None -> false

let unsupported_exp ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-concatn-chunks"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let unsupported_source ctx origin source_echo reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-concatn-chunks"
    ~source_echo
    ~reason
    ~suggestion
    ()

let lower_type_arg ctx env origin = function
  | { it = TypA typ; _ } ->
    Expr_translate.lower_type_witness
      ctx
      env
      origin
      ~constructor:"Premise/IfPr/inverse-concatn-chunks/static-arg"
      typ
  | arg ->
    { Expr_result.term = None
    ; guards = []
    ; diagnostics =
        [ unsupported_source
            ctx
            origin
            (Il.Print.string_of_arg arg)
            "fixed-width concatn inverse requires TypP parameters to be passed as TypA witnesses"
            "Keep this equality Unsupported until the static syntax argument is preserved"
        ]
    }

type concatn_call_shape =
  { omitted_exp : exp
  ; known_terms : term list
  ; guards : eq_condition list
  ; diagnostics : Diagnostics.t list
  ; known_runtime : (exp * term) list
  }

let collect_concatn_call_shape ctx env origin ~omitted_param_index params args =
  let rec loop index omitted_exp known_terms guards diagnostics known_runtime params args =
    match params, args with
    | [], [] ->
      (match omitted_exp with
      | Some omitted_exp ->
        Ok
          { omitted_exp
          ; known_terms = List.rev known_terms
          ; guards = List.rev guards
          ; diagnostics = List.rev diagnostics
          ; known_runtime = List.rev known_runtime
          }
      | None ->
        Error
          [ unsupported_source ctx origin "inverse metadata"
              "validated concatn inverse omitted parameter is absent from the source call"
              "Keep this equality Unsupported until the source call matches its declaration"
          ])
    | Analysis.Function_graph.Runtime_exp :: params, { it = ExpA exp; _ } :: args
      when index = omitted_param_index ->
      loop (index + 1) (Some exp) known_terms guards diagnostics known_runtime params args
    | Analysis.Function_graph.Static_typ :: params, arg :: args ->
      let result = lower_type_arg ctx env origin arg in
      (match result.term with
      | Some term ->
        loop (index + 1) omitted_exp (term :: known_terms)
          (List.rev_append result.guards guards)
          (List.rev_append result.diagnostics diagnostics)
          known_runtime params args
      | None ->
        Error result.diagnostics)
    | Analysis.Function_graph.Runtime_exp :: params, { it = ExpA exp; _ } :: args ->
      let result = lower_with_source_carrier ctx env origin exp in
      (match result.term with
      | Some term ->
        loop (index + 1) omitted_exp (term :: known_terms)
          (List.rev_append result.guards guards)
          (List.rev_append result.diagnostics diagnostics)
          ((exp, term) :: known_runtime) params args
      | None -> Error result.diagnostics)
    | (Analysis.Function_graph.Static_def | Analysis.Function_graph.Static_gram) :: _, arg :: _ ->
      Error
        [ unsupported_source
            ctx
            origin
            (Il.Print.string_of_arg arg)
            "fixed-width concatn inverse currently supports only TypP static arguments"
            "Keep this equality Unsupported until DefP/GramP static arguments are represented in the helper contract"
        ]
    | Analysis.Function_graph.Runtime_exp :: _,
      ({ it = TypA _ | DefA _ | GramA _; _ } as arg) :: _ ->
      Error
        [ unsupported_source
            ctx
            origin
            (Il.Print.string_of_arg arg)
            "runtime concatn argument position received a static argument"
            "Preserve source parameter kinds before using fixed-width concatn inverse"
        ]
    | [], _ :: _ | _ :: _, [] ->
      Error
        [ unsupported_source
            ctx
            origin
            (String.concat " " (List.map Il.Print.string_of_arg args))
            "source-declared concatn inverse call arity does not match its DecD parameters"
            "Keep this equality Unsupported until the forward definition parameters and call arguments align"
        ]
  in
  loop 0 None [] [] [] [] params args

let target names env ~bound_vars source_exp =
  match unbound_direct_var env ~bound_vars source_exp with
  | None -> None
  | Some id ->
    (match typed_var_for_exp names id source_exp with
    | Some (_term, binding)
      when sort_name binding.Expr_env.sort = "SpectecTerminals" ->
      Some (id.it, binding)
    | Some _ | None ->
      (match source_exp.note.it with
      | IterT (_, ListN _) ->
        let sort = sort "SpectecTerminals" in
        let term =
          Local_name.source_qualified names id.it (sort_ref sort)
        in
        Some (id.it, { Expr_env.term; sort; typ = source_exp.note })
      | _ -> None))

type bytes_arg =
  | Bytes_target
  | Bytes_capture of Request.capture

let bytes_arg_formal target_head_var = function
  | Bytes_target -> Var target_head_var
  | Bytes_capture capture -> Var capture.Request.formal_var

let lower_bytes_args
    ctx env origin names generator_id ~omitted_param_index params args =
  let rec loop index names roles guards diagnostics params args =
    match params, args with
    | [], [] ->
      Ok (List.rev roles, List.rev guards, List.rev diagnostics, names)
    | Analysis.Function_graph.Runtime_exp :: params, { it = ExpA arg_exp; _ } :: args
      when index = omitted_param_index && exp_is_var generator_id arg_exp ->
      loop (index + 1) names (Bytes_target :: roles) guards diagnostics params args
    | Analysis.Function_graph.Runtime_exp :: _, { it = ExpA arg_exp; _ } :: _
      when index = omitted_param_index ->
      Error
        [ unsupported_exp ctx origin arg_exp
            "validated inner inverse omits a parameter other than the ListN generator element"
            "Keep this equality Unsupported unless the generator occupies the declared inverse output position"
        ]
    | Analysis.Function_graph.Runtime_exp :: _, { it = ExpA arg_exp; _ } :: _
      when exp_is_var generator_id arg_exp ->
        Error
          [ unsupported_exp
              ctx
              origin
              arg_exp
              "inner bytes function uses the ListN generator variable more than once"
              "Keep this equality Unsupported until the inverse target is linear in the bytes function call"
          ]
    | Analysis.Function_graph.Runtime_exp :: params, { it = ExpA arg_exp; _ } :: args ->
        let result = lower_with_source_carrier ctx env origin arg_exp in
        (match result.term, Expr_translate.carrier_sort_of_typ arg_exp.note with
        | Some term, Some sort ->
          let capture, names =
            let source_id, formal_var, names =
              match arg_exp.it with
              | VarE id ->
                ( id.it
                , Local_name.source_qualified_name
                    names id.it (sort_ref sort)
                , names )
              | _ ->
                let formal_var, names =
                  Local_name.fresh_qualified_name
                    names Local_name.Capture (sort_ref sort)
                in
                source_echo_exp arg_exp, formal_var, names
            in
            ( { Request.source_id
              ; call_term = term
              ; formal_var
              ; sort
              ; typ = arg_exp.note
              }
            , names )
          in
          loop
            (index + 1)
            names
            (Bytes_capture capture :: roles)
            (List.rev_append result.guards guards)
            (List.rev_append result.diagnostics diagnostics)
            params args
        | None, _ | _, None ->
          Error
            (result.diagnostics
             @ [ unsupported_exp
                   ctx
                   origin
                   arg_exp
                   "known argument to the inner bytes function could not lower to a Maude carrier term"
                   "Bind the bytes function arguments through earlier premises before using fixed-width concatn inverse"
               ]))
    | (Analysis.Function_graph.Static_typ
      | Analysis.Function_graph.Static_def
      | Analysis.Function_graph.Static_gram) :: _, arg :: _
    | Analysis.Function_graph.Runtime_exp :: _,
      ({ it = TypA _ | DefA _ | GramA _; _ } as arg) :: _ ->
      Error
        [ unsupported_source
            ctx
            origin
            (Il.Print.string_of_arg arg)
            "inner bytes inverse arguments outside runtime ExpA are not represented by the structural decode helper"
            "Keep this equality Unsupported until those source parameter kinds are preserved in the helper key"
        ]
    | [], _ :: _ | _ :: _, [] ->
      Error
        [ unsupported_source ctx origin "inner bytes call"
            "inner bytes function call arity does not match its DecD parameters"
            "Keep this equality Unsupported until source parameters and arguments align"
        ]
  in
  loop 0 names [] [] [] params args

let chunks_shape runtime_exp =
  match runtime_exp.it with
  | IterE (body, (ListN (count_exp, None), [ generator_id, source_exp ])) ->
    (match body.it with
    | CallE (bytes_id, bytes_args) ->
      Some (bytes_id, bytes_args, count_exp, generator_id, source_exp)
    | _ -> None)
  | _ -> None

let has_unbound_chunks_source env ~bound_vars args =
  args
  |> List.exists (fun arg ->
    match arg.it with
    | ExpA exp ->
      (match chunks_shape exp with
      | Some (_, _, _, _, source_exp) ->
        Option.is_some (unbound_direct_var env ~bound_vars source_exp)
      | None -> false)
    | TypA _ | DefA _ | GramA _ -> false)

let inverse_definition_implemented
    ctx
    (inverse_definition : Analysis.Function_graph.definition) =
  inverse_definition.clause_count > 0
  ||
  match Builtin_registry.find (Context.builtins ctx) inverse_definition.id with
  | Some { status = Builtin_registry.Implemented; _ } -> true
  | Some { status = Obligation; _ } | None -> false

let inverse_result_is_terminal
    (inverse_definition : Analysis.Function_graph.definition) =
  match Expr_translate.carrier_sort_of_typ inverse_definition.result with
  | Some sort -> sort_name sort = "SpectecTerminal"
  | None -> false

let inverse_result_is_chunks
    (inverse_definition : Analysis.Function_graph.definition) =
  match Expr_translate.carrier_sort_of_typ inverse_definition.result with
  | Some sort -> sort_name sort = "SpectecTerminals"
  | None -> false

let lower names ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (concatn_id, concatn_args) ->
    if not (has_unbound_chunks_source env ~bound_vars concatn_args) then None else
    let graph = Context.function_graph ctx in
    let concatn_target = call_target_id ctx concatn_id in
    (match
       Analysis.Function_graph.find_definition graph concatn_target.it,
       Analysis.Function_graph.definition_inverse_status graph concatn_target.it
     with
    | Some definition, Invalid_inverse { reason; hint_origin }
      when List.length definition.params = List.length concatn_args ->
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            [ unsupported_exp ctx origin exp
                (reason ^ "; inverse hint declared at " ^ Origin.summary hint_origin)
                "Correct the outer inverse metadata or keep this concatn reconstruction Unsupported"
            ]
        }
    | Some definition, Valid_inverse outer_inverse
      when List.length definition.params = List.length concatn_args ->
      (match
         collect_concatn_call_shape ctx env origin
           ~omitted_param_index:outer_inverse.omitted_param_index
           definition.params concatn_args
       with
      | Error diagnostics ->
        Some { (empty_with_env ~bound_vars env) with diagnostics }
      | Ok shape ->
        (match chunks_shape shape.omitted_exp, shape.known_runtime with
        | None, _ ->
          Some
            { (empty_with_env ~bound_vars env) with
              diagnostics =
                shape.diagnostics
                @ [ unsupported_exp ctx origin exp
                      "the fixed ListN chunk source is not the parameter omitted by the validated outer inverse"
                      "Keep this equality Unsupported unless inverse metadata identifies that source parameter"
                  ]
            }
        | Some _, [] | Some _, _ :: _ :: _ ->
          Some
            { (empty_with_env ~bound_vars env) with
              diagnostics =
                shape.diagnostics
                @ [ unsupported_exp ctx origin exp
                      "concatn reconstruction requires exactly one known runtime width argument outside the omitted chunk stream"
                      "Keep broader outer inverse signatures Unsupported until their structural role is documented"
                  ]
            }
        | Some (bytes_id, bytes_args, count_exp, generator_id, source_exp), [ _ ] ->
          let bytes_target = call_target_id ctx bytes_id in
          (match target names env ~bound_vars source_exp with
          | None -> None
          | Some (target_source_id, target_binding) ->
            (match
               Analysis.Function_graph.find_definition graph bytes_target.it,
               Analysis.Function_graph.definition_inverse_status graph bytes_target.it
             with
            | Some _, Invalid_inverse { reason; hint_origin } ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    shape.diagnostics
                    @ [ unsupported_exp ctx origin exp
                          (reason ^ "; inverse hint declared at "
                           ^ Origin.summary hint_origin)
                          "Correct the source inverse metadata or keep this fixed-width inverse premise Unsupported"
                      ]
                }
            | Some bytes_definition, Valid_inverse _
              when List.length bytes_definition.params <> List.length bytes_args ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    shape.diagnostics
                    @ [ unsupported_exp ctx origin exp
                          "inner bytes function call arity does not match its DecD parameters"
                          "Keep this equality Unsupported until the element bytes function parameters and call arguments align"
                      ]
                }
            | Some bytes_definition, Valid_inverse inner_inverse ->
              (match
                 Analysis.Function_graph.find_definition
                   graph inner_inverse.inverse_id
               with
              | None ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      shape.diagnostics
                      @ [ unsupported_exp ctx origin exp
                            ("source-declared inverse target `"
                             ^ inner_inverse.inverse_id
                             ^ "` has no DecD declaration")
                            "Declare the inverse function in SpecTec source or keep this equality Unsupported"
                        ]
                  }
              | Some inverse_definition
                when not (inverse_definition_implemented ctx inverse_definition) ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      shape.diagnostics
                      @ [ unsupported_exp ctx origin exp
                            ("source-declared inverse `"
                             ^ inner_inverse.inverse_id
                             ^ "` has no implemented source or builtin contract")
                            "Implement the inverse in the verified builtin/prelude backend before using it in fixed-width concatn inverse"
                        ]
                  }
              | Some inverse_definition
                when not (inverse_result_is_terminal inverse_definition) ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      shape.diagnostics
                      @ [ unsupported_exp ctx origin exp
                            ("source-declared inverse `"
                             ^ inner_inverse.inverse_id
                             ^ "` does not return a terminal element")
                            "Keep this equality Unsupported until the inverse result type matches the chunk element"
                        ]
                  }
              | Some inverse_definition ->
                let capture_source_ids =
                  bytes_args
                  |> List.filter_map (fun arg ->
                    match arg.it with
                    | ExpA { it = VarE id; _ }
                      when id.it <> generator_id.it -> Some id.it
                    | ExpA _ | TypA _ | DefA _ | GramA _ -> None)
                  |> List.sort_uniq String.compare
                in
                let helper_names =
                  Local_name.reserve_sources
                    Local_name.empty
                    (generator_id.it :: capture_source_ids)
                in
                let target_head_var =
                  Local_name.source_qualified_name
                    helper_names generator_id.it
                    (sort_ref (sort "SpectecTerminal"))
                in
                (match
                   lower_bytes_args
                     ctx env origin helper_names generator_id
                     ~omitted_param_index:inner_inverse.omitted_param_index
                     bytes_definition.params bytes_args
                 with
                | Error diagnostics ->
                  Some { (empty_with_env ~bound_vars env) with diagnostics }
                | Ok (arg_roles, arg_guards, arg_diagnostics, helper_names) ->
                  let known_result =
                    lower_with_source_carrier ctx env origin known_exp
                  in
                  let count_result =
                    Expr_translate.lower_numeric_guard_value
                      ctx env origin count_exp
                  in
                  (match known_result.term, count_result.term with
                  | None, _ | _, None ->
                    Some
                      { (empty_with_env ~bound_vars env) with
                        diagnostics =
                          shape.diagnostics @ arg_diagnostics
                          @ known_result.diagnostics
                          @ count_result.diagnostics
                          @ [ unsupported_exp ctx origin exp
                                "concatn reconstruction could not lower the known result or source count"
                                "Bind the known result and count before invoking the declared inverse"
                            ]
                      }
                  | Some known_term, Some count_term ->
                    let captures =
                      arg_roles
                      |> List.filter_map (function
                        | Bytes_target -> None
                        | Bytes_capture capture -> Some capture)
                    in
                    let capture_terms =
                      List.map
                        (fun capture -> capture.Request.call_term)
                        captures
                    in
                    let bytes_call_formals =
                      List.map (bytes_arg_formal target_head_var) arg_roles
                    in
                    let target_stream_var, helper_names =
                      Local_name.fresh_qualified_name
                        helper_names Local_name.Stream
                        (sort_ref (sort "SpectecTerminals"))
                    in
                    let chunks_tail_var, helper_names =
                      Local_name.fresh_qualified_name
                        helper_names Local_name.Tail
                        (sort_ref (sort "SpectecTerminals"))
                    in
                    let chunk_var, _ =
                      Local_name.fresh_qualified_name
                        helper_names Local_name.Chunk
                        (sort_ref (sort "SpectecTerminals"))
                    in
                    let inverse_call_formals =
                      List.map
                        (fun capture -> Var capture.Request.formal_var)
                        captures
                      @ [ Var chunk_var ]
                    in
                    if
                      List.length inverse_definition.params
                      <> List.length inverse_call_formals
                    then
                      Some
                        { (empty_with_env ~bound_vars env) with
                          diagnostics =
                            shape.diagnostics @ arg_diagnostics
                            @ [ unsupported_exp ctx origin exp
                                  ("source-declared inverse `"
                                   ^ inner_inverse.inverse_id
                                   ^ "` arity does not match the generated chunk inverse call")
                                  "Keep this equality Unsupported until the inverse signature matches the chunk binding shape"
                              ]
                        }
                    else
                      let prefix_conditions =
                        shape.guards @ arg_guards @ known_result.guards
                        @ count_result.guards
                      in
                      let prefix_bound =
                        conditions_bound_vars
                          ~constructor_op:
                            (Condition_closure.source_constructor_certificate ctx)
                          bound_vars prefix_conditions
                      in
                      let outer_inverse_terms =
                        shape.known_terms @ [ known_term ]
                      in
                      let outer_inverse_call =
                        app
                          (Context.definition_op ctx
                             { concatn_id with it = outer_inverse.inverse_id })
                          outer_inverse_terms
                      in
                      let inverse_args_bound =
                        Condition_closure.term_vars outer_inverse_call
                        |> List.for_all (fun var -> List.mem var prefix_bound)
                      in
                      (match
                         Analysis.Function_graph.find_definition
                           graph outer_inverse.inverse_id
                       with
                      | None ->
                        Some
                          { (empty_with_env ~bound_vars env) with
                            diagnostics =
                              shape.diagnostics @ arg_diagnostics
                              @ known_result.diagnostics
                              @ count_result.diagnostics
                              @ [ unsupported_exp ctx origin exp
                                    ("source-declared outer inverse target `"
                                     ^ outer_inverse.inverse_id
                                     ^ "` has no DecD declaration")
                                    "Declare and implement the outer inverse before concatn reconstruction"
                                ]
                          }
                      | Some outer_definition
                        when not
                               (inverse_definition_implemented
                                  ctx outer_definition)
                             || not (inverse_result_is_chunks outer_definition) ->
                        Some
                          { (empty_with_env ~bound_vars env) with
                            diagnostics =
                              shape.diagnostics @ arg_diagnostics
                              @ known_result.diagnostics
                              @ count_result.diagnostics
                              @ [ unsupported_exp ctx origin exp
                                    "declared outer inverse is unimplemented or does not return chunk-preserving sequence data"
                                    "Keep this concatn reconstruction Unsupported until the declared inverse contract is implemented"
                                ]
                          }
                      | Some outer_definition
                        when List.length outer_definition.params
                             <> List.length outer_inverse_terms ->
                        Some
                          { (empty_with_env ~bound_vars env) with
                            diagnostics =
                              shape.diagnostics @ arg_diagnostics
                              @ known_result.diagnostics
                              @ count_result.diagnostics
                              @ [ unsupported_exp ctx origin exp
                                    "declared outer inverse arity does not match the concatn reconstruction call"
                                    "Correct the inverse metadata or keep this equality Unsupported"
                                ]
                          }
                      | Some _ when not inverse_args_bound ->
                        Some
                          { (empty_with_env ~bound_vars env) with
                            diagnostics =
                              shape.diagnostics @ arg_diagnostics
                              @ known_result.diagnostics
                              @ count_result.diagnostics
                              @ [ unsupported_exp ctx origin exp
                                    "declared outer inverse uses variables that are not bound before concatn reconstruction"
                                    "Bind every inverse input through earlier source premises"
                                ]
                          }
                      | Some _ ->
                        let helper_request =
                          { Request.kind =
                              Request.Decode_chunks
                                { source = source_echo_exp exp
                                ; target_source_id
                                ; bytes_op =
                                    Context.definition_op ctx bytes_target
                                ; inverse_op =
                                    Context.definition_op ctx
                                      { bytes_id with
                                        it = inner_inverse.inverse_id
                                      }
                                ; captures
                                ; bytes_call_formals
                                ; inverse_call_formals
                                ; target_head_var
                                ; target_stream_var
                                ; chunks_tail_var
                                ; chunk_var
                                }
                          ; reason =
                              "structural decode of chunks returned by the declared outer inverse"
                          ; origin
                          }
                        in
                        let helper_name =
                          Helper.request (Context.helpers ctx) helper_request
                        in
                        let outer_chunks, _ =
                          Local_name.fresh_qualified names Local_name.Chunk
                            (sort_ref (sort "SpectecTerminals"))
                        in
                        let decode_pattern =
                          app
                            (Helper_materialize_inverse.decode_chunks_result_op
                               helper_name)
                            [ target_binding.term ]
                        in
                        Context.record_definition_call ctx outer_inverse_call
                          (Analysis.Function_graph.plain_identity
                             outer_inverse.inverse_id);
                        let env_after =
                          Expr_env.add env target_source_id target_binding
                        in
                        let original_result =
                          lower_with_source_carrier
                            ctx env_after origin call_exp
                        in
                        (match original_result.term with
                        | None ->
                          Some
                            { (empty_with_env ~bound_vars env_after) with
                              diagnostics =
                                shape.diagnostics @ arg_diagnostics
                                @ known_result.diagnostics
                                @ count_result.diagnostics
                                @ original_result.diagnostics
                            }
                        | Some original_term ->
                          let decode_subject =
                            app
                              (Helper_materialize_inverse.decode_chunks_op
                                 helper_name)
                              (capture_terms @ [ outer_chunks ])
                          in
                          let conditions =
                            prefix_conditions
                            @ [ MatchCond (outer_chunks, outer_inverse_call)
                              ; EqCond
                                  (app "len" [ outer_chunks ], count_term)
                              ; MatchCond (decode_pattern, decode_subject)
                              ]
                            @ original_result.guards
                            @ [ EqCond (original_term, known_term) ]
                          in
                          let pattern_certificate =
                            Condition_pattern_certificate.generated
                              [ Helper_materialize_inverse.decode_chunks_result_constructor
                                  helper_name origin
                              ]
                          in
                          Some
                            (with_conditions
                               ~pattern_certificate
                               ctx
                               env_after
                               bound_vars
                               conditions
                               (shape.diagnostics @ arg_diagnostics
                                @ known_result.diagnostics
                                @ count_result.diagnostics
                                @ original_result.diagnostics)))))))
            | _ ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    shape.diagnostics
                    @ [ unsupported_exp ctx origin exp
                          "fixed-width concatn inverse requires an unbound sequence target and an inverse-hinted element bytes function"
                          "Do not lower arbitrary concatn inverse search without source inverse metadata for the element function"
                      ]
                }))))
    | Some _, No_inverse
    | Some _, Invalid_inverse _
    | Some _, Valid_inverse _
    | None, _ -> None)
  | _ -> None
