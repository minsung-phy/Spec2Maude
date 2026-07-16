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
  | Inverse_target of string * Expr_env.binding

type inverse_arg_item =
  { param : Analysis.Function_graph.param_kind
  ; arg : inverse_arg
  ; term : term
  }

let app name args =
  App (name, args)

let call_target_id ctx id =
  match Context.find_static_def ctx id.it with
  | Some target_id -> { id with it = target_id }
  | None -> id

let unsupported_exp ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-binding"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let unsupported_arg ctx origin arg reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-binding"
    ~source_echo:(Il.Print.string_of_arg arg)
    ~reason
    ~suggestion
    ()

let lower_inverse_arg names ctx env ~bound_vars origin exp =
  match unbound_env_var_binding env ~bound_vars exp with
  | Some (id, binding) ->
    if Condition_closure.is_match_pattern
         ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
         binding.term then
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
      (match typed_var_for_exp names id exp with
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

let lower_inverse_arg_for_param names ctx env ~bound_vars origin param arg =
  match param, arg.it with
  | Analysis.Function_graph.Runtime_exp, ExpA exp ->
    lower_inverse_arg names ctx env ~bound_vars origin exp
  | Static_typ, TypA typ ->
    let result =
      Expr_translate.lower_type_witness
        ctx
        env
        origin
        ~constructor:"Premise/IfPr/inverse-binding/static-arg/TypP"
        typ
    in
    (match result.term with
    | Some term ->
      Ok (Inverse_known term, term, result.guards, result.diagnostics)
    | None -> Error result.diagnostics)
  | Runtime_exp, (TypA _ | DefA _ | GramA _) ->
    Error
      [ unsupported_arg
          ctx
          origin
          arg
          "runtime inverse parameter position received a static argument"
          "Preserve source parameter/argument kinds before using inverse lowering"
      ]
  | Static_typ, (ExpA _ | DefA _ | GramA _) ->
    Error
      [ unsupported_arg
          ctx
          origin
          arg
          "TypP inverse parameter position requires a TypA argument"
          "Keep this equality Unsupported until the static argument kind matches the source DecD parameter"
      ]
  | Static_def, DefA _
  | Static_def, (ExpA _ | TypA _ | GramA _)
  | Static_gram, _ ->
    Error
      [ unsupported_arg
          ctx
          origin
          arg
          "inverse binding with DefP/GramP static arguments is outside this source-declared inverse slice"
          "Materialize a finite specialization before using this inverse equality"
      ]

let collect_inverse_args names ctx env ~bound_vars origin exp params args =
  let rec loop items guards diagnostics params args =
    match params, args with
    | [], [] -> Ok (List.rev items, List.rev guards, List.rev diagnostics)
    | param :: params, source_arg :: args ->
      (match lower_inverse_arg_for_param names ctx env ~bound_vars origin param source_arg with
      | Error new_diagnostics ->
        Error (List.rev_append diagnostics new_diagnostics)
      | Ok (arg, term, new_guards, new_diagnostics) ->
        let item = { param; arg; term } in
        loop
          (item :: items)
          (List.rev_append new_guards guards)
          (List.rev_append new_diagnostics diagnostics)
          params
          args)
    | [], _ :: _ | _ :: _, [] ->
      Error
        [ unsupported_exp
            ctx
            origin
            exp
            "source-declared inverse argument arity changed during lowering"
            "Keep this equality Unsupported until the forward definition parameters and source call arguments align"
        ]
  in
  loop [] [] [] params args

let direct_runtime_target names ctx env ~bound_vars origin exp =
  match unbound_env_var_binding env ~bound_vars exp with
  | Some (id, binding) ->
    if Condition_closure.is_match_pattern
         ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
         binding.term then
      Ok (Some id)
    else
      Error
        [ unsupported_exp
            ctx
            origin
            exp
            ("unbound inverse target `" ^ id
             ^ "` is not represented by a Maude match pattern")
            "Keep this equality Unsupported until the target can be bound by a matching condition"
        ]
  | None ->
    (match unbound_direct_var env ~bound_vars exp with
    | Some id ->
      (match typed_var_for_exp names id exp with
      | Some _ -> Ok (Some id.it)
      | None ->
        Error
          [ unsupported_exp
              ctx
              origin
              exp
              ("unbound inverse target `" ^ id.it
               ^ "` has no known Maude carrier sort")
              "Keep this equality Unsupported until the target type has a carrier-preserving encoding"
          ])
    | None -> Ok None)

let direct_runtime_targets names ctx env ~bound_vars origin params args =
  let step acc item =
    match acc with
    | Error diagnostics -> Error diagnostics
    | Ok targets ->
      (match item with
      | Analysis.Function_graph.Runtime_exp, { it = ExpA exp; _ } ->
        (match direct_runtime_target names ctx env ~bound_vars origin exp with
        | Ok None -> Ok targets
        | Ok (Some id) -> Ok (id :: targets)
        | Error diagnostics -> Error diagnostics)
      | Runtime_exp, { it = TypA _ | DefA _ | GramA _; _ }
      | Static_typ, _
      | Static_def, _
      | Static_gram, _ ->
        Ok targets)
  in
  List.fold_left step (Ok []) (List.combine params args)

let inverse_known_terms args =
  args
  |> List.filter_map (function
    | { arg = Inverse_known term; _ } -> Some term
    | { arg = Inverse_target _; _ } -> None)

let inverse_target args =
  args
  |> List.filter_map (function
    | { arg = Inverse_known _; _ } -> None
    | { arg = Inverse_target (id, binding); _ } -> Some (id, binding))

let inverse_original_terms args =
  args
  |> List.map (function
    | { arg = Inverse_known term; _ } -> term
    | { arg = Inverse_target (_id, binding); _ } -> binding.Expr_env.term)

let inverse_target_admissible
    (inverse_definition : Analysis.Function_graph.definition)
    target_binding =
  match Expr_translate.carrier_sort_of_typ inverse_definition.result with
  | Some sort ->
    sort_name sort = sort_name target_binding.Expr_env.sort
  | None -> false

let inverse_definition_implemented
    ctx
    (inverse_definition : Analysis.Function_graph.definition) =
  inverse_definition.clause_count > 0
  ||
  match Builtin_registry.find (Context.builtins ctx) inverse_definition.id with
  | Some { status = Builtin_registry.Implemented; _ } -> true
  | Some { status = Obligation; _ } | None -> false

let invalid_inverse_demand ctx origin exp reason hint_origin =
  unsupported_exp
    ctx
    origin
    exp
    (reason ^ "; inverse hint declared at " ^ Origin.summary hint_origin)
    "Correct the source inverse metadata or keep this inverse-binding premise Unsupported"

let lower names ctx env ~bound_vars origin exp call_exp known_exp =
  match call_exp.it with
  | CallE (id, args) ->
    let graph = Context.function_graph ctx in
    let target_id = call_target_id ctx id in
    (match
       Analysis.Function_graph.find_definition graph target_id.it,
       Analysis.Function_graph.definition_inverse_status graph target_id.it
     with
    | Some definition, Invalid_inverse { reason; hint_origin }
      when List.length definition.params = List.length args ->
      (match direct_runtime_targets names ctx env ~bound_vars origin definition.params args with
      | Error diagnostics ->
        Some { (empty_with_env ~bound_vars env) with diagnostics }
      | Ok [] -> None
      | Ok (_ :: _) ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              [ invalid_inverse_demand ctx origin exp reason hint_origin ]
          })
    | Some definition, Valid_inverse inverse_id
      when List.length definition.params = List.length args ->
      (match direct_runtime_targets names ctx env ~bound_vars origin definition.params args with
      | Error diagnostics ->
        Some { (empty_with_env ~bound_vars env) with diagnostics }
      | Ok [] -> None
      | Ok (_ :: _ :: _) ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              [ unsupported_exp
                  ctx
                  origin
                  exp
                  "source-declared inverse equality has more than one direct unbound runtime target"
                  "Keep this equality Unsupported until a source-derived multi-output inverse model is documented"
              ]
          }
      | Ok [ _target ] ->
        (match Analysis.Function_graph.find_definition graph inverse_id with
        | None ->
          Some
            { (empty_with_env ~bound_vars env) with
              diagnostics =
                [ unsupported_exp
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
                  [ unsupported_exp
                      ctx
                      origin
                      exp
                      ("source-declared inverse `" ^ inverse_id
                       ^ "` has no implemented source or builtin contract")
                      "Implement the inverse in the verified builtin/prelude backend before using it to bind a value"
                  ]
              }
          else
          (match collect_inverse_args names ctx env ~bound_vars origin exp definition.params args with
          | Error diagnostics ->
            Some { (empty_with_env ~bound_vars env) with diagnostics }
          | Ok (arg_items, arg_guards, arg_diagnostics) ->
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
                let inverse_terms = inverse_known_terms arg_items @ [ known_term ] in
                if List.length inverse_definition.params <> List.length inverse_terms then
                  Some
                    { (empty_with_env ~bound_vars env) with
                      diagnostics =
                        arg_diagnostics @ known_result.diagnostics
                        @ [ unsupported_exp
                              ctx
                              origin
                              exp
                              ("source-declared inverse `" ^ inverse_id
                               ^ "` arity does not match the generated inverse call")
                              "Keep this equality Unsupported until the inverse signature matches the forward binding shape"
                          ]
                    }
                else if not (inverse_target_admissible inverse_definition target_binding) then
                  Some
                    { (empty_with_env ~bound_vars env) with
                      diagnostics =
                        arg_diagnostics @ known_result.diagnostics
                        @ [ unsupported_exp
                              ctx
                              origin
                              exp
                              ("source-declared inverse `" ^ inverse_id
                               ^ "` result carrier does not match the unbound target carrier")
                              "Keep this equality Unsupported until the inverse result type matches the missing source argument"
                          ]
                    }
                else
                  let inverse_id_phrase = { id with it = inverse_id } in
                  let inverse_call =
                    app (Context.definition_op ctx inverse_id_phrase) inverse_terms
                  in
                  let original_call =
                    app
                      (Context.definition_op ctx target_id)
                      (inverse_original_terms arg_items)
                  in
                  Context.record_definition_call ctx inverse_call
                    (Analysis.Function_graph.plain_identity inverse_id);
                  Context.record_definition_call ctx original_call
                    (Analysis.Function_graph.plain_identity target_id.it);
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
                      Expr_env.add env target_id_text target_binding
                    in
                    Some
                      (with_conditions
                         ctx
                         env_after
                         bound_vars
                         conditions
                         (arg_diagnostics @ known_result.diagnostics)))
            | [] | _ :: _ :: _ -> None))))
    | Some _, No_inverse
    | Some _, Invalid_inverse _
    | Some _, Valid_inverse _
    | None, _ -> None)
  | _ -> None
