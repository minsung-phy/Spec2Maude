open Il.Ast
open Maude_ir
open Util.Source

open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_exp = Premise_diagnostic.source_echo_exp
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let with_conditions = Premise_state.with_conditions
let unbound_direct_var = Premise_state.unbound_direct_var
let unbound_env_var_binding = Premise_state.unbound_env_var_binding
let typed_var_for_exp = Premise_state.typed_var_for_exp
let lower_with_source_carrier = Premise_shape.lower_with_source_carrier

type inverse_arg =
  | Inverse_known of term
  | Inverse_target of string * Expr_translate.binding

let app name args =
  App (name, args)

let call_target_id ctx id =
  match Context.find_static_def ctx id.it with
  | Some target_id -> { id with it = target_id }
  | None -> id

let definition_has_only_runtime_params definition =
  definition.Analysis.Function_graph.params
  |> List.for_all (function
    | Analysis.Function_graph.Runtime_exp -> true
    | Static_typ | Static_def | Static_gram -> false)

let unsupported_exp ctx origin exp reason suggestion =
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
        [ unsupported_exp
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
          [ unsupported_exp
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

let lower ctx env ~bound_vars origin exp call_exp known_exp =
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
                      @ [ unsupported_exp
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
