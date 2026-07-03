open Il.Ast
open Maude_ir
open Util.Source

open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_exp = Premise_diagnostic.source_echo_exp
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

let pair_list_body left_id right_id body =
  match body.it with
  | ListE [ left; right ] when exp_is_var left_id left && exp_is_var right_id right ->
    true
  | _ -> false

let target env ~bound_vars source_exp =
  match unbound_direct_var env ~bound_vars source_exp with
  | None -> None
  | Some id ->
    (match typed_var_for_exp id source_exp with
    | Some (_term, binding)
      when sort_name binding.Expr_translate.sort = "SpectecTerminals" ->
      Some (id.it, binding)
    | Some _ | None -> None)

let unsupported_exp ctx origin exp reason suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/inverse-pair-split"
    ~source_echo:(source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let pair_split_shape runtime_exp =
  match runtime_exp.it with
  | IterE (body, (List, [ left_id, left_source; right_id, right_source ]))
    when pair_list_body left_id right_id body ->
    Some (body, left_id, left_source, right_id, right_source)
  | _ -> None

let lower ctx env ~bound_vars origin exp call_exp known_exp =
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
        (match pair_split_shape runtime_exp with
        | None -> None
        | Some (body, left_id, left_source, right_id, right_source) ->
          (match
             target env ~bound_vars left_source,
             target env ~bound_vars right_source
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
                  [ unsupported_exp
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
