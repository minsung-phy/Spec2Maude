open Maude_ir

let rec term_matches_general general specific =
  match general, specific with
  | Var _, _ -> true
  | Const left, Const right -> left = right
  | Qid left, Qid right -> left = right
  | App (left_name, left_args), App (right_name, right_args) ->
    left_name = right_name
    && List.length left_args = List.length right_args
    && List.for_all2 term_matches_general left_args right_args
  | _ -> false

let terms_match_general general specific =
  List.length general = List.length specific
  && List.for_all2 term_matches_general general specific

let rec term_vars = function
  | Var name -> [ name ]
  | Const _ | Qid _ -> []
  | App (_, args) ->
    args
    |> List.concat_map term_vars
    |> List.sort_uniq String.compare

let rec substitute_term subst = function
  | Var name as term ->
    (match List.assoc_opt name subst with
    | None -> term
    | Some replacement -> replacement)
  | Const _ | Qid _ as term -> term
  | App (name, args) -> App (name, List.map (substitute_term subst) args)

let substitute_condition subst = function
  | EqCond (left, right) ->
    EqCond (substitute_term subst left, substitute_term subst right)
  | BoolCond term -> BoolCond (substitute_term subst term)
  | MatchCond (left, right) ->
    MatchCond (substitute_term subst left, substitute_term subst right)
  | MembershipCond (term, sort) ->
    MembershipCond (substitute_term subst term, sort)

let condition_vars = function
  | EqCond (left, right) | MatchCond (left, right) ->
    term_vars left @ term_vars right |> List.sort_uniq String.compare
  | BoolCond term | MembershipCond (term, _) ->
    term_vars term |> List.sort_uniq String.compare

let rec collect_pattern_subst subst subject pattern =
  match pattern with
  | Var name ->
    (match List.assoc_opt name subst with
    | None -> Some ((name, subject) :: subst)
    | Some previous when previous = subject -> Some subst
    | Some _ -> Some subst)
  | Const _ | Qid _ -> Some subst
  | App (pattern_name, pattern_args) ->
    (match subject with
    | App (subject_name, subject_args)
      when pattern_name = subject_name
           && List.length pattern_args = List.length subject_args ->
      List.fold_left2
        (fun subst subject pattern ->
          match subst with
          | None -> None
          | Some subst -> collect_pattern_subst subst subject pattern)
        (Some subst)
        subject_args
        pattern_args
    | _ ->
      if term_vars pattern = [] then
        Some subst
      else
        None)

let collect_head_subst subjects patterns =
  if List.length subjects <> List.length patterns then
    None
  else
    List.fold_left2
      (fun subst subject pattern ->
        match subst with
        | None -> None
        | Some subst -> collect_pattern_subst subst subject pattern)
      (Some [])
      subjects
      patterns

let rec is_closed_pattern = function
  | Var _ -> false
  | Const _ | Qid _ -> true
  | App (_, args) -> List.for_all is_closed_pattern args

let head_mismatch_conditions subjects patterns =
  let rec term_mismatches seen subject pattern =
    match pattern with
    | Var name ->
      (match List.assoc_opt name seen with
      | Some previous when previous = subject -> Some (seen, [])
      | Some previous ->
        Some (seen, [ BoolCond (App ("_=/=_", [ subject; previous ])) ])
      | None -> Some ((name, subject) :: seen, []))
    | Const _ | Qid _ ->
      Some (seen, [ BoolCond (App ("_=/=_", [ subject; pattern ])) ])
    | App (pattern_name, pattern_args) ->
      (match subject with
      | App (subject_name, subject_args)
        when pattern_name = subject_name
             && List.length pattern_args = List.length subject_args ->
        List.fold_left2
          (fun state subject pattern ->
            match state with
            | None -> None
            | Some (seen, acc) ->
              (match term_mismatches seen subject pattern with
              | None -> None
              | Some (seen, conditions) -> Some (seen, acc @ conditions)))
          (Some (seen, []))
          subject_args
          pattern_args
      | _ ->
        if is_closed_pattern pattern then
          Some (seen, [ BoolCond (App ("_=/=_", [ subject; pattern ])) ])
        else
          None)
  in
  let rec loop seen acc = function
    | [], [] -> Some (List.rev acc)
    | subject :: subjects, pattern :: patterns ->
      (match term_mismatches seen subject pattern with
      | None -> None
      | Some (seen, conditions) ->
        loop seen (List.rev_append conditions acc) (subjects, patterns))
    | _ -> None
  in
  loop [] [] (subjects, patterns)

let guard_bool_op = function
  | "typecheck"
  | "typecheckSeq"
  | "typecheckOptSeq"
  | "typecheckSeqOpt"
  | "typecheckNestedSeq"
  | "isOpt"
  | "allOpt"
  | "allLen" -> true
  | _ -> false

let is_guard_bool_term = function
  | App (name, _) -> guard_bool_op name
  | Var _ | Const _ | Qid _ -> false

let negate_bool_term = function
  | App ("_==_", [ left; right ]) -> App ("_=/=_", [ left; right ])
  | App ("_=/=_", [ left; right ]) -> App ("_==_", [ left; right ])
  | term -> App ("not_", [ term ])

type complement_atom =
  | Skip_guard
  | Negated of eq_condition
  | Blocked

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let add_vars vars bound =
  vars
  |> List.fold_left
       (fun bound var -> if List.mem var bound then bound else var :: bound)
       bound

let complement_atom bound = function
  | EqCond (left, right) when left = right -> Skip_guard
  | EqCond (left, right)
    when not (vars_subset (term_vars left @ term_vars right) bound) ->
    Blocked
  | EqCond (left, right) ->
    Negated (BoolCond (App ("_=/=_", [ left; right ])))
  | BoolCond term when not (vars_subset (term_vars term) bound) -> Blocked
  | BoolCond term when is_guard_bool_term term -> Skip_guard
  | BoolCond term -> Negated (BoolCond (negate_bool_term term))
  | MatchCond (Var name, subject)
    when List.mem name bound
         && vars_subset (term_vars subject) bound ->
    if Var name = subject then
      Skip_guard
    else
      Negated (BoolCond (App ("_=/=_", [ Var name; subject ])))
  | MatchCond (Var _, subject) when vars_subset (term_vars subject) bound ->
    Skip_guard
  | MatchCond (left, right)
    when vars_subset (term_vars left @ term_vars right) bound ->
    Negated (BoolCond (App ("_=/=_", [ left; right ])))
  | MembershipCond (term, _) when vars_subset (term_vars term) bound ->
    Skip_guard
  | MatchCond _ | MembershipCond _ -> Blocked

let positive_condition_bound bound = function
  | MatchCond (pattern, subject)
    when vars_subset (term_vars subject) bound ->
    Some (add_vars (term_vars pattern) bound)
  | EqCond _ | BoolCond _ | MembershipCond _ | MatchCond _ -> None

let condition_bool_term = function
  | BoolCond term -> Some term
  | EqCond (left, right) -> Some (App ("_==_", [ left; right ]))
  | MatchCond _ | MembershipCond _ -> None

let has_runtime_vars condition =
  condition_vars condition <> []

let rec or_terms = function
  | [] -> None
  | [ term ] -> Some term
  | term :: terms ->
    (match or_terms terms with
    | None -> Some term
    | Some rest -> Some (App ("_or_", [ term; rest ])))

let sequential_condition_complements bound conditions =
  let rec loop bound prefix candidates = function
    | [] -> List.rev candidates
    | condition :: rest ->
      let candidates =
        match complement_atom bound condition with
        | Negated negated when has_runtime_vars condition ->
          (List.rev prefix, negated) :: candidates
        | Skip_guard | Blocked | Negated _ -> candidates
      in
      let bound, prefix =
        match positive_condition_bound bound condition with
        | Some bound -> bound, condition :: prefix
        | None -> bound, prefix
      in
      loop bound prefix candidates rest
  in
  loop bound [] [] conditions

let sequential_complement_conditions lhs_terms eq_conditions =
  let bound =
    lhs_terms
    |> List.concat_map term_vars
    |> List.sort_uniq String.compare
  in
  match sequential_condition_complements bound eq_conditions with
  | [] -> None
  | (prefix, negated) :: rest ->
    let prefix, negated =
      List.fold_left (fun _ item -> item) (prefix, negated) rest
    in
    Some
      (List.map (fun condition -> EqCondition condition) prefix
       @ [ EqCondition negated ])

let direct_complement_conditions current_terms predecessor_terms conditions =
  match collect_head_subst current_terms predecessor_terms with
  | None -> None
  | Some subst ->
    (match head_mismatch_conditions current_terms predecessor_terms with
    | None -> None
    | Some head_mismatches ->
      let conditions = List.map (substitute_condition subst) conditions in
      let bound =
        current_terms
        |> List.concat_map term_vars
        |> List.sort_uniq String.compare
      in
      let candidates = sequential_condition_complements bound conditions in
      let head_terms =
        head_mismatches |> List.filter_map condition_bool_term
      in
      match candidates, head_terms with
      | [], [] -> None
      | [], _ ->
        (match or_terms head_terms with
        | None -> None
        | Some term -> Some [ EqCondition (BoolCond term) ])
      | (prefix, negated) :: rest, [] ->
        let chosen_prefix, chosen_negated =
          List.fold_left (fun _ item -> item) (prefix, negated) rest
        in
        Some
          (List.map (fun condition -> EqCondition condition) chosen_prefix
           @ [ EqCondition chosen_negated ])
      | _ :: _, _ ->
        (match or_terms head_terms with
        | None -> None
        | Some term -> Some [ EqCondition (BoolCond term) ]))

let rec has_constructor_refinement current previous =
  match current, previous with
  | Var _, App _ -> true
  | App (current_op, current_args), App (previous_op, previous_args)
    when String.equal current_op previous_op
         && List.length current_args = List.length previous_args ->
    List.exists2 has_constructor_refinement current_args previous_args
  | Var _, _ | Const _, _ | Qid _, _ | App _, _ -> false

let has_constructor_refinement_terms current previous =
  List.length current = List.length previous
  && List.exists2 has_constructor_refinement current previous

let predecessor_matches_current current predecessor =
  terms_match_general current predecessor

let predecessor_refines_constructor current predecessor =
  has_constructor_refinement_terms current predecessor
