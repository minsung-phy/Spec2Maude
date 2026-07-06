open Maude_ir
open Helper_request

let term_vars term =
  let rec loop acc = function
    | Var name -> name :: acc
    | Const _ | Qid _ -> acc
    | App (_, args) -> List.fold_left loop acc args
  in
  loop [] term |> List.sort_uniq String.compare

let add_unique vars acc =
  List.fold_left
    (fun acc var -> if List.exists (( = ) var) acc then acc else var :: acc)
    acc vars

let vars_within bound vars =
  vars |> List.for_all (fun var -> List.exists (( = ) var) bound)

let condition_required_vars bound = function
  | EqCond (lhs, rhs) ->
    term_vars lhs @ term_vars rhs
    |> List.sort_uniq String.compare
    |> List.filter (fun var -> not (List.exists (( = ) var) bound))
  | MatchCond (_pattern, subject) ->
    term_vars subject
    |> List.filter (fun var -> not (List.exists (( = ) var) bound))
  | MembershipCond (subject, _)
  | BoolCond subject ->
    term_vars subject
    |> List.filter (fun var -> not (List.exists (( = ) var) bound))

let condition_bound_vars = function
  | MatchCond (pattern, _subject) -> term_vars pattern
  | EqCond _ | MembershipCond _ | BoolCond _ -> []

let scheduled_condition bound = function
  | MatchCond (pattern, subject)
    when vars_within bound (term_vars pattern) ->
    EqCond (pattern, subject)
  | condition -> condition

let schedule_eq_conditions initial_bound conditions =
  let rec loop bound scheduled remaining =
    match remaining with
    | [] -> Some (List.rev scheduled)
    | _ ->
      (match
         remaining
         |> List.find_opt (fun condition ->
           vars_within bound (condition_required_vars bound condition))
       with
      | None -> None
      | Some chosen ->
        let remaining =
          remaining |> List.filter (fun condition -> condition != chosen)
        in
        let scheduled_chosen = scheduled_condition bound chosen in
        let bound = add_unique (condition_bound_vars chosen) bound in
        loop bound (scheduled_chosen :: scheduled) remaining)
  in
  loop initial_bound [] conditions

let spectec_terminal = sort "SpectecTerminal"
let spectec_terminals = sort "SpectecTerminals"
let spectec_type = sort "SpectecType"
let nat = sort "Nat"

let app name args =
  App (name, args)

let concat left right =
  app "_ _" [ left; right ]

let generated name origin node =
  Maude_ir.generated ~provenance:(Helper name) ~origin node

let helper_call_multi name sources captures =
  app name (sources @ List.map (fun capture -> Var capture.formal_var) captures)

let helper_call name first captures =
  helper_call_multi name [ first ] captures

let helper_call_from_tail name (map : iter_map) =
  helper_call name (Var map.source_tail_var) map.captures

let not_eps tail_var =
  BoolCond (app "_=/=_" [ Var tail_var; Const "eps" ])

let succ term =
  app "s_" [ term ]

let result_bound_conditions (map : iter_map) =
  let conditions =
    map.body_eq_conditions
    @ [ MatchCond (Var map.body_result_var, map.lowered_body) ]
  in
  let initial_bound =
    map.helper_head_var :: List.map (fun capture -> capture.formal_var) map.captures
  in
  match schedule_eq_conditions initial_bound conditions with
  | Some scheduled -> scheduled
  | None -> conditions

let result_bound_conditions_for
    ~initial_bound
    ~body_result_var
    ~lowered_body
    ~body_eq_conditions =
  let conditions = body_eq_conditions @ [ MatchCond (Var body_result_var, lowered_body) ] in
  match schedule_eq_conditions initial_bound conditions with
  | Some scheduled -> scheduled
  | None -> conditions

let output_item_term = function
  | Output_flat_terminal, body_result_var -> Var body_result_var
  | Output_nested_seq, body_result_var -> app "seq" [ Var body_result_var ]

let output_item_sort = function
  | Output_flat_terminal -> spectec_terminal
  | Output_nested_seq -> spectec_terminals

let source_item_term source_item_shape head =
  match source_item_shape with
  | Source_flat_terminal -> head
  | Source_nested_seq -> app "seq" [ head ]
