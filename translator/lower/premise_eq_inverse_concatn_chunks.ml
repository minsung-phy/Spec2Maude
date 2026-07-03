open Il.Ast
open Maude_ir
open Util.Source

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

let runtime_args args =
  args
  |> List.filter_map (fun arg ->
    match arg.it with
    | ExpA exp -> Some exp
    | TypA _ | DefA _ | GramA _ -> None)

let target env ~bound_vars source_exp =
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

type bytes_arg =
  | Bytes_target
  | Bytes_capture of Helper.capture

let bytes_arg_formal target_head_var = function
  | Bytes_target -> Var target_head_var
  | Bytes_capture capture -> Var capture.Helper.formal_var

let lower_bytes_args ctx env origin stem generator_id args =
  let rec loop index target_seen roles guards diagnostics = function
    | [] ->
      if target_seen then
        Ok (List.rev roles, List.rev guards, List.rev diagnostics)
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
          (index + 1)
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
  loop 0 false [] [] [] args

let chunks_shape runtime_exp =
  match runtime_exp.it with
  | IterE (body, (ListN (count_exp, None), [ generator_id, source_exp ])) ->
    (match body.it with
    | CallE (bytes_id, bytes_args) ->
      Some (body, bytes_id, bytes_args, count_exp, generator_id, source_exp)
    | _ -> None)
  | _ -> None

let lower ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (concatn_id, concatn_args) ->
    let graph = Context.function_graph ctx in
    let concatn_target = call_target_id ctx concatn_id in
    (match
       Analysis.Function_graph.find_definition graph concatn_target.it,
       Analysis.Function_graph.definition_inverse graph concatn_target.it
     with
    | Some _, Some _ ->
      (match runtime_args concatn_args with
      | [ runtime_exp; width_exp ] ->
        (match chunks_shape runtime_exp with
        | None -> None
        | Some (_body, bytes_id, bytes_args, count_exp, generator_id, source_exp) ->
          let bytes_target = call_target_id ctx bytes_id in
          (match
             Analysis.Function_graph.find_definition graph bytes_target.it,
             Analysis.Function_graph.definition_inverse graph bytes_target.it,
             target env ~bound_vars source_exp
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
               lower_bytes_args
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
                  arg_roles |> List.map (bytes_arg_formal target_head_var)
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
                      @ [ unsupported_exp
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
                  [ unsupported_exp
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
