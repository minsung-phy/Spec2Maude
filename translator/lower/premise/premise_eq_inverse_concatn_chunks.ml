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
  { static_guards : Maude_ir.eq_condition list
  ; static_diagnostics : Diagnostics.t list
  ; runtime_args : exp list
  }

let collect_concatn_call_shape ctx env origin params args =
  let rec loop static_guards static_diagnostics runtime_args params args =
    match params, args with
    | [], [] ->
      Ok
        { static_guards = List.rev static_guards
        ; static_diagnostics = List.rev static_diagnostics
        ; runtime_args = List.rev runtime_args
        }
    | Analysis.Function_graph.Static_typ :: params, arg :: args ->
      let result = lower_type_arg ctx env origin arg in
      (match result.term with
      | Some _ ->
        loop
          (List.rev_append result.guards static_guards)
          (List.rev_append result.diagnostics static_diagnostics)
          runtime_args
          params
          args
      | None ->
        Error result.diagnostics)
    | Runtime_exp :: params, { it = ExpA exp; _ } :: args ->
      loop static_guards static_diagnostics (exp :: runtime_args) params args
    | (Static_def | Static_gram) :: _, arg :: _ ->
      Error
        [ unsupported_source
            ctx
            origin
            (Il.Print.string_of_arg arg)
            "fixed-width concatn inverse currently supports only TypP static arguments"
            "Keep this equality Unsupported until DefP/GramP static arguments are represented in the helper contract"
        ]
    | Runtime_exp :: _, ({ it = TypA _ | DefA _ | GramA _; _ } as arg) :: _ ->
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
  loop [] [] [] params args

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

let lower_bytes_args ctx env origin names generator_id args =
  let rec loop names target_seen roles guards diagnostics = function
    | [] ->
      if target_seen then
        Ok (List.rev roles, List.rev guards, List.rev diagnostics, names)
      else
        Error
          [ unsupported_source
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
          names
          true
          (Bytes_target :: roles)
          guards
          diagnostics
          rest
      | ExpA arg_exp when exp_is_var generator_id arg_exp ->
        Error
          [ unsupported_exp
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
            names
            target_seen
            (Bytes_capture capture :: roles)
            (List.rev_append result.guards guards)
            (List.rev_append result.diagnostics diagnostics)
            rest
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
      | TypA _ | DefA _ | GramA _ ->
        Error
          [ unsupported_source
              ctx
              origin
              (Il.Print.string_of_arg arg)
              "inner bytes function has a static argument, which is outside this fixed-width concatn inverse slice"
              "Keep this equality Unsupported until static bytes-function arguments are represented in the helper key"
          ])
  in
  loop names false [] [] [] args

let chunks_shape runtime_exp =
  match runtime_exp.it with
  | IterE (body, (ListN (count_exp, None), [ generator_id, source_exp ])) ->
    (match body.it with
    | CallE (bytes_id, bytes_args) ->
      Some (bytes_id, bytes_args, count_exp, generator_id, source_exp)
    | _ -> None)
  | _ -> None

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

let lower names ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (concatn_id, concatn_args) ->
    let graph = Context.function_graph ctx in
    let concatn_target = call_target_id ctx concatn_id in
    (match
       Analysis.Function_graph.find_definition graph concatn_target.it,
       Analysis.Function_graph.definition_inverse graph concatn_target.it
     with
    | Some definition, Some _ ->
      (match collect_concatn_call_shape ctx env origin definition.params concatn_args with
      | Error diagnostics ->
        Some { (empty_with_env ~bound_vars env) with diagnostics }
      | Ok { static_guards; static_diagnostics; runtime_args } ->
      (match runtime_args with
      | [ runtime_exp; width_exp ] ->
        (match chunks_shape runtime_exp with
        | None -> None
        | Some (bytes_id, bytes_args, count_exp, generator_id, source_exp) ->
          let bytes_target = call_target_id ctx bytes_id in
          (match
             Analysis.Function_graph.find_definition graph bytes_target.it,
             Analysis.Function_graph.definition_inverse_status graph bytes_target.it,
             target names env ~bound_vars source_exp
           with
          | Some bytes_definition, Valid_inverse inverse_id, Some (target_source_id, target_binding)
            when List.length bytes_definition.params = List.length bytes_args ->
            (match Analysis.Function_graph.find_definition graph inverse_id with
            | None ->
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    static_diagnostics
                    @ [ unsupported_exp
                          ctx
                          origin
                          exp
                          ("source-declared inverse target `" ^ inverse_id
                           ^ "` has no DecD declaration")
                          "Declare the inverse function in SpecTec source or keep this equality Unsupported"
                      ]
                }
            | Some inverse_definition ->
            if not (inverse_definition_implemented ctx inverse_definition) then
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    static_diagnostics
                    @ [ unsupported_exp
                          ctx
                          origin
                          exp
                          ("source-declared inverse `" ^ inverse_id
                           ^ "` has no implemented source or builtin contract")
                          "Implement the inverse in the verified builtin/prelude backend before using it in fixed-width concatn inverse"
                      ]
                }
            else if not (inverse_result_is_terminal inverse_definition) then
              Some
                { (empty_with_env ~bound_vars env) with
                  diagnostics =
                    static_diagnostics
                    @ [ unsupported_exp
                          ctx
                          origin
                          exp
                          ("source-declared inverse `" ^ inverse_id
                           ^ "` does not return a terminal element")
                          "Keep this equality Unsupported until the inverse result type matches the chunk element"
                      ]
                }
            else
            let capture_source_ids =
              bytes_args
              |> List.filter_map (fun arg ->
                match arg.it with
                | ExpA { it = VarE id; _ } when id.it <> generator_id.it ->
                  Some id.it
                | ExpA _ | TypA _ | DefA _ | GramA _ -> None)
              |> List.sort_uniq String.compare
            in
            let helper_names =
              Local_name.reserve_sources
                Local_name.empty (generator_id.it :: capture_source_ids)
            in
            let target_head_var =
              Local_name.source_qualified_name
                helper_names generator_id.it
                (sort_ref (sort "SpectecTerminal"))
            in
            (match
               lower_bytes_args
                 ctx env origin helper_names generator_id bytes_args
             with
            | Error diagnostics ->
              Some { (empty_with_env ~bound_vars env) with diagnostics }
            | Ok (arg_roles, arg_guards, arg_diagnostics, helper_names) ->
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
                  captures |> List.map (fun capture -> capture.Request.call_term)
                in
                let bytes_call_formals =
                  arg_roles |> List.map (bytes_arg_formal target_head_var)
                in
                let target_stream_var, helper_names =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Stream
                    (sort_ref (sort "SpectecTerminals"))
                in
                let bytes_var, helper_names =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Stream
                    (sort_ref (sort "SpectecTerminals"))
                in
                let bytes_head_var, helper_names =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Byte
                    (sort_ref (sort "SpectecTerminal"))
                in
                let bytes_tail_var, helper_names =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Tail
                    (sort_ref (sort "SpectecTerminals"))
                in
                let width_var, helper_names =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Width (sort_ref (sort "Nat"))
                in
                let count_tail_var, helper_names =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Count (sort_ref (sort "Nat"))
                in
                let chunk_var, _ =
                  Local_name.fresh_qualified_name
                    helper_names Local_name.Chunk
                    (sort_ref (sort "SpectecTerminals"))
                in
                let inverse_call_formals =
                  (captures
                   |> List.map (fun capture -> Var capture.Request.formal_var))
                  @ [ Var chunk_var ]
                in
                if List.length inverse_definition.params
                   <> List.length inverse_call_formals then
                  Some
                    { (empty_with_env ~bound_vars env) with
                      diagnostics =
                        static_diagnostics @ arg_diagnostics
                        @ [ unsupported_exp
                              ctx
                              origin
                              exp
                              ("source-declared inverse `" ^ inverse_id
                               ^ "` arity does not match the generated chunk inverse call")
                              "Keep this equality Unsupported until the inverse signature matches the chunk binding shape"
                          ]
                    }
                else
                let helper_request =
                  { Request.kind =
                      Request.Inverse_concatn_chunks
                        { source = source_echo_exp exp
                        ; target_source_id
                        ; bytes_op = Context.definition_op ctx bytes_target
                        ; inverse_op =
                            Context.definition_op ctx { bytes_id with it = inverse_id }
                        ; captures
                        ; bytes_call_formals
                        ; inverse_call_formals
                        ; target_head_var
                        ; target_stream_var
                        ; bytes_var
                        ; bytes_head_var
                        ; bytes_tail_var
                        ; width_var
                        ; count_tail_var
                        ; chunk_var
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
                    (Helper_materialize_inverse.concatn_chunks_inverse_op helper_name)
                    (capture_terms @ [ known_term; width_term; count_term ])
                in
                let inverse_pattern =
                  app
                    (Helper_materialize_inverse.concatn_chunks_result_op helper_name)
                    [ target_binding.term ]
                in
                let prefix_conditions =
                  static_guards @ arg_guards @ known_result.guards
                  @ width_result.guards @ count_result.guards
                in
                let prefix_bound =
                  conditions_bound_vars
                    ~constructor_op:
                      (Condition_closure.source_constructor_certificate ctx)
                    bound_vars prefix_conditions
                in
                let inverse_args_bound =
                  Condition_closure.term_vars inverse_subject
                  |> List.for_all (fun var -> List.mem var prefix_bound)
                in
                if not inverse_args_bound then
                  Some
                    { (empty_with_env ~bound_vars env) with
                        diagnostics =
                        static_diagnostics @ arg_diagnostics
                        @ known_result.diagnostics
                        @ width_result.diagnostics @ count_result.diagnostics
                        @ [ unsupported_exp
                              ctx
                              origin
                              exp
                              "fixed-width concatn inverse uses count, width, bytes, or capture variables that are not bound before the matching condition"
                              "Bind those inputs through earlier premises before emitting this helper MatchCond"
                          ]
                    }
                else
                  let env_after =
                    Expr_env.add env target_source_id target_binding
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
                    let pattern_certificate =
                      Condition_pattern_certificate.generated
                        [ Helper_materialize_inverse.concatn_chunks_result_constructor
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
                         (static_diagnostics @ arg_diagnostics
                          @ known_result.diagnostics
                          @ width_result.diagnostics @ count_result.diagnostics
                          @ original_result.diagnostics))
                  | None ->
                    Some
                      { (empty_with_env ~bound_vars env_after) with
                          diagnostics =
                          static_diagnostics @ arg_diagnostics
                          @ known_result.diagnostics
                          @ width_result.diagnostics @ count_result.diagnostics
                          @ original_result.diagnostics
                      })
              | _ ->
                Some
                  { (empty_with_env ~bound_vars env) with
                    diagnostics =
                      static_diagnostics @ arg_diagnostics
                      @ known_result.diagnostics
                      @ width_result.diagnostics @ count_result.diagnostics
                      @ [ unsupported_exp
                            ctx
                            origin
                            exp
                            "fixed-width concatn inverse could not lower bytes, count, or width to Maude terms"
                            "Keep this equality Unsupported until bytes, count, and width are admissible before the inverse binding"
                        ]
                  }))
            )
          | Some _, Invalid_inverse { reason; hint_origin }, Some _ ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  static_diagnostics
                  @ [ unsupported_exp
                        ctx
                        origin
                        exp
                        (reason ^ "; inverse hint declared at "
                         ^ Origin.summary hint_origin)
                        "Correct the source inverse metadata or keep this fixed-width inverse premise Unsupported"
                    ]
              }
          | Some _, Valid_inverse _, Some _ ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  static_diagnostics
                  @ [ unsupported_exp
                        ctx
                        origin
                        exp
                        "inner bytes function call arity does not match its DecD parameters"
                        "Keep this equality Unsupported until the element bytes function parameters and call arguments align"
                    ]
              }
          | _ ->
            Some
              { (empty_with_env ~bound_vars env) with
                diagnostics =
                  static_diagnostics
                  @ [ unsupported_exp
                      ctx
                      origin
                      exp
                      "fixed-width concatn inverse requires an unbound sequence target and an inverse-hinted element bytes function"
                      "Do not lower arbitrary concatn inverse search without source inverse metadata for the element function"
                  ]
              }))
      | [] | [ _ ] | _ :: _ :: _ :: _ -> None))
    | _ -> None)
  | _ -> None
