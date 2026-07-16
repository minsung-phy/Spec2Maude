type t =
  { positive : Maude_ir.eq_condition list
  ; failure : Maude_ir.eq_condition list list
  }

let rec term_vars = function
  | Maude_ir.Var name -> [ name ]
  | Maude_ir.Const _ | Maude_ir.Qid _ -> []
  | Maude_ir.App (_, args) ->
    args |> List.concat_map term_vars |> List.sort_uniq String.compare

let condition_vars = function
  | Maude_ir.EqCond (left, right)
  | Maude_ir.MatchCond (left, right) ->
    term_vars left @ term_vars right
  | Maude_ir.BoolCond term
  | Maude_ir.MembershipCond (term, _) -> term_vars term

let vars_bound bound conditions =
  conditions
  |> List.concat_map condition_vars
  |> List.for_all (fun var -> List.mem var bound)

let certify ~bound_vars ~positive ~failure =
  match positive with
  | [] -> None
  | _ when not (vars_bound bound_vars positive) -> None
  | _ when not (List.for_all (vars_bound bound_vars) failure) -> None
  | _ -> Some { positive; failure }

let matches_equality left right = function
  | Maude_ir.EqCond (actual_left, actual_right)
  | Maude_ir.MatchCond (actual_left, actual_right) ->
    (actual_left = left && actual_right = right)
    || (actual_left = right && actual_right = left)
  | Maude_ir.BoolCond (Maude_ir.App ("_==_", [ actual_left; actual_right ])) ->
    (actual_left = left && actual_right = right)
    || (actual_left = right && actual_right = left)
  | Maude_ir.BoolCond _ | Maude_ir.MembershipCond _ -> false

let certify_equality
    ~bound_vars ~left ~right ~requirements ~failure positive =
  let matching = List.filter (matches_equality left right) positive in
  match matching with
  | [ equality ] when positive = requirements @ [ equality ] ->
    certify ~bound_vars ~positive ~failure
  | [] | _ :: _ :: _ | [ _ ] -> None
