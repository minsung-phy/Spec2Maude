open Maude_ir

type result =
  | Complete of eq_condition list list
  | Blocked of string

let vars terms =
  terms |> List.concat_map Condition_closure.term_vars |> List.sort_uniq String.compare

let subset left right = List.for_all (fun item -> List.mem item right) left

let total_op = function
  | "typecheck" | "typecheckSeq" | "typecheckOptSeq" | "typecheckSeqOpt"
  | "typecheckNestedSeq" | "isOpt" | "allOpt" | "allLen" | "contains"
  | "ratIsInt" | "_==_" | "_=/=_" | "_<_" | "_<=_" | "_>_" | "_>=_"
  | "_and_" | "_or_" | "not_" -> true
  | _ -> false

let total_observer = function
  | "typecheck" | "typecheckSeq" | "typecheckOptSeq" | "typecheckSeqOpt"
  | "typecheckNestedSeq" -> true
  | _ -> false

let rec total_term pattern_certificate term =
  Condition_pattern_certificate.is_pattern pattern_certificate term
  || match term with
     | App (_, []) -> true
     | App (name, args) ->
       total_op name && List.for_all (total_term pattern_certificate) args
     | Var _ | Const _ | Qid _ -> true

let total_terms pattern_certificate terms =
  List.for_all (total_term pattern_certificate) terms

let total_bool_term pattern_certificate = function
  | Const ("true" | "false") -> true
  | App (name, _) when total_observer name -> true
  | App (name, args) ->
    total_op name && List.for_all (total_term pattern_certificate) args
  | Var _ | Const _ | Qid _ -> false

let bool_blocker = function
  | App (name, _) when not (total_op name) ->
    "head Boolean guard uses non-total operator " ^ name
  | App _ -> "head Boolean guard contains a partial argument"
  | Var _ -> "head Boolean guard is an unconstrained variable"
  | Const value -> "head Boolean guard is non-Boolean constant " ^ value
  | Qid value -> "head Boolean guard is non-Boolean identifier " ^ value

let rec loop pattern_certificate bound prefix alternatives = function
  | [] -> Complete (List.rev alternatives)
  | EqCond (left, right) :: guards when left = right ->
    loop pattern_certificate bound prefix alternatives guards
  | EqCond (left, right) as guard :: guards ->
    if not (subset (vars [ left; right ]) bound) then
      Blocked "head equality guard refers to a variable not bound by the matched head"
    else if not (total_terms pattern_certificate [ left; right ]) then
      Blocked "head equality guard contains a partial or otherwise non-total term"
    else
      let failure = List.rev prefix @ [ BoolCond (App ("_=/=_", [ left; right ])) ] in
      loop pattern_certificate bound (guard :: prefix) (failure :: alternatives) guards
  | BoolCond term as guard :: guards ->
    if not (subset (Condition_closure.term_vars term) bound) then
      Blocked "head Boolean guard refers to a variable not bound by the matched head"
    else if not (total_bool_term pattern_certificate term) then
      Blocked (bool_blocker term)
    else
      let failure = List.rev prefix @ [ EqCond (term, Const "false") ] in
      loop pattern_certificate bound (guard :: prefix) (failure :: alternatives) guards
  | MatchCond (Var name, subject) as guard :: guards
    when subset (Condition_closure.term_vars subject) bound
         && total_term pattern_certificate subject ->
    if List.mem name bound then
      let failure =
        List.rev prefix @ [ BoolCond (App ("_=/=_", [ Var name; subject ])) ]
      in
      loop pattern_certificate bound (guard :: prefix) (failure :: alternatives) guards
    else
      loop pattern_certificate (name :: bound) (guard :: prefix) alternatives guards
  | MatchCond (pattern, subject) as guard :: guards
    when subset (vars [ pattern; subject ]) bound
         && total_terms pattern_certificate [ pattern; subject ] ->
    let failure =
      List.rev prefix @ [ BoolCond (App ("_=/=_", [ pattern; subject ])) ]
    in
    loop pattern_certificate bound (guard :: prefix) (failure :: alternatives) guards
  | MatchCond _ :: _ ->
    Blocked "head matching guard contains an unbound or non-total subject/pattern"
  | MembershipCond _ :: _ ->
    Blocked "head membership guard has no source-complete structural non-membership complement"

let complement
    ?(pattern_certificate = Condition_pattern_certificate.empty)
    ~bound_terms guards =
  loop pattern_certificate (vars bound_terms) [] [] guards
