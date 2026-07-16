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
          Option.bind subst (fun subst ->
            collect_pattern_subst subst subject pattern))
        (Some subst)
        subject_args
        pattern_args
    | _ ->
      if term_vars pattern = [] then Some subst else None)

let collect_head_subst subjects patterns =
  if List.length subjects <> List.length patterns then None
  else
    List.fold_left2
      (fun subst subject pattern ->
        Option.bind subst (fun subst ->
          collect_pattern_subst subst subject pattern))
      (Some [])
      subjects
      patterns

let specialize_terms subjects patterns terms =
  collect_head_subst subjects patterns
  |> Option.map (fun subst -> List.map (substitute_term subst) terms)
