open Maude_ir
open Expr_env

module Request = Helper_request

let capture_candidates env ids =
  ids
  |> List.fold_left
       (fun captures source_id ->
         match find env source_id with
         | Some ({ term = Var _; _ } as binding) ->
           (source_id, binding) :: captures
         | Some _ | None -> captures)
       []
  |> List.rev

let available_capture_candidates env ids =
  ids
  |> List.filter_map (fun source_id ->
    Option.map (fun binding -> source_id, binding) (find env source_id))

let required_capture_candidates env ~required_vars ids =
  ids
  |> List.fold_left
       (fun captures source_id ->
         match find env source_id with
         | Some ({ term = Var var_name; _ } as binding)
           when List.mem var_name required_vars ->
           (source_id, var_name, binding) :: captures
         | Some _ | None -> captures)
       []
  |> List.rev

let captured_vars candidates =
  candidates
  |> List.map (fun (_source_id, var_name, _binding) -> var_name)
  |> List.sort_uniq String.compare

let missing_required_vars ~required_vars ~captured_vars =
  required_vars
  |> List.filter (fun var_name -> not (List.mem var_name captured_vars))

let make_required_captures names candidates =
  candidates
  |> List.map (fun (source_id, _var_name, (binding : binding)) ->
    { Request.source_id
    ; call_term = binding.term
    ; formal_var =
        Local_name.source_qualified_name names source_id (sort_ref binding.sort)
    ; sort = binding.sort
    ; typ = binding.typ
    })

let make_captures names candidates =
  candidates
  |> List.map (fun (source_id, (binding : binding)) ->
    { Request.source_id
    ; call_term = binding.term
    ; formal_var =
        Local_name.source_qualified_name names source_id (sort_ref binding.sort)
    ; sort = binding.sort
    ; typ = binding.typ
    })

let capture_vars captures =
  captures |> List.map (fun capture -> capture.Request.formal_var)

let capture_env captures =
  captures
  |> List.fold_left
       (fun env capture ->
         add env capture.Request.source_id
           { term = Var capture.Request.formal_var
           ; sort = capture.Request.sort
           ; typ = capture.Request.typ
           })
       empty

let filter_used_captures used_vars captures =
  captures
  |> List.filter (fun capture ->
    List.mem capture.Request.formal_var used_vars)

let filter_captures_by_call_vars used_vars captures =
  captures
  |> List.filter (fun capture ->
    Condition_closure.term_vars capture.Request.call_term
    |> List.exists (fun var -> List.mem var used_vars))
