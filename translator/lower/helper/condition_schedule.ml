open Maude_ir

let term_vars term =
  let rec loop acc = function
    | Var name -> name :: acc
    | Const _ | Qid _ -> acc
    | App (_, args) -> List.fold_left loop acc args
  in
  loop [] term |> List.sort_uniq String.compare

let add_unique vars acc =
  List.fold_left
    (fun acc var -> if List.mem var acc then acc else var :: acc)
    acc vars

let vars_within bound vars =
  List.for_all (fun var -> List.mem var bound) vars

let condition_required_vars bound = function
  | EqCond (lhs, rhs) ->
    term_vars lhs @ term_vars rhs
    |> List.sort_uniq String.compare
    |> List.filter (fun var -> not (List.mem var bound))
  | MatchCond (_pattern, subject) ->
    term_vars subject
    |> List.filter (fun var -> not (List.mem var bound))
  | MembershipCond (subject, _)
  | BoolCond subject ->
    term_vars subject
    |> List.filter (fun var -> not (List.mem var bound))

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
         List.find_opt
           (fun condition ->
             vars_within bound (condition_required_vars bound condition))
           remaining
       with
      | None -> None
      | Some chosen ->
        let remaining = List.filter (fun condition -> condition != chosen) remaining in
        let scheduled_chosen = scheduled_condition bound chosen in
        let bound = add_unique (condition_bound_vars chosen) bound in
        loop bound (scheduled_chosen :: scheduled) remaining)
  in
  loop initial_bound [] conditions
