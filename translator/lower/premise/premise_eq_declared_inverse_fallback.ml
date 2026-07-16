open Il.Ast
open Util.Source

open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_exp = Premise_diagnostic.source_echo_exp

let call_target_id ctx id =
  match Context.find_static_def ctx id.it with
  | Some target_id -> { id with it = target_id }
  | None -> id

let source_unbound_vars env ~bound_vars exp =
  Source_free_vars.exp_ids exp
  |> List.filter (fun id ->
    not (Premise_state.source_id_is_bound env bound_vars id))

let inverse_contract_reason ctx graph inverse_id =
  match Analysis.Function_graph.find_definition graph inverse_id with
  | None ->
    ( "source-declared inverse target `" ^ inverse_id ^ "` has no DecD declaration"
    , "Declare the inverse function in SpecTec source or keep this equality Unsupported" )
  | Some inverse_definition
    when inverse_definition.Analysis.Function_graph.clause_count = 0
         && (match Builtin_registry.find (Context.builtins ctx) inverse_id with
             | Some { status = Builtin_registry.Obligation; _ } | None -> true
             | Some { status = Implemented; _ } -> false) ->
    ( "source-declared inverse `" ^ inverse_id
      ^ "` is a builtin obligation and cannot be replaced by a translator helper"
    , "Implement the inverse in the verified builtin/prelude backend before using it to bind nested source structure" )
  | Some _ ->
    ( "source-declared inverse `" ^ inverse_id
      ^ "` would have to bind nested source structure after all documented structural inverse slices failed"
    , "Add a source-isomorphic destructuring lowering for this IL shape, or keep this equality Unsupported" )

let invalid_inverse_reason reason hint_origin =
  ( reason ^ "; inverse hint declared at " ^ Origin.summary hint_origin
  , "Correct the source inverse metadata or keep this inverse-binding premise Unsupported" )

let lower ctx env ~bound_vars origin exp call_exp _known_exp =
  match call_exp.it with
  | CallE (id, _args) ->
    let graph = Context.function_graph ctx in
    let target_id = call_target_id ctx id in
    let unbound_vars = source_unbound_vars env ~bound_vars call_exp in
    if unbound_vars = [] then
      None
    else
      (match Analysis.Function_graph.definition_inverse_status graph target_id.it with
      | No_inverse -> None
      | Invalid_inverse { reason; hint_origin } ->
        let reason, suggestion = invalid_inverse_reason reason hint_origin in
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IfPr/declared-inverse-fallback"
                  ~source_echo:(source_echo_exp exp)
                  ~reason
                  ~suggestion
                  ()
              ]
          }
      | Valid_inverse inverse_id ->
        let reason, suggestion = inverse_contract_reason ctx graph inverse_id in
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IfPr/declared-inverse-fallback"
                  ~source_echo:(source_echo_exp exp)
                  ~reason
                  ~suggestion
                  ()
              ]
          })
  | _ -> None
