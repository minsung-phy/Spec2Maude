open Maude_ir

let rec term_vars = function
  | Var name -> [ name ]
  | Const _ | Qid _ -> []
  | App (_, args) ->
    args
    |> List.map term_vars
    |> List.concat
    |> List.sort_uniq String.compare

let add_vars vars bound =
  List.fold_left
    (fun bound var -> if List.mem var bound then bound else var :: bound)
    bound
    vars

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let prelude_true = function
  | Const "true" -> true
  | App ("isOpt", [ Const "eps" ])
  | App ("allOpt", [ Const "eps" ])
  | App ("allLen", [ Const "eps"; _ ])
  | App
      ( ( "typecheckSeq"
        | "typecheckOptSeq"
        | "typecheckSeqOpt"
        | "typecheckNestedSeq" )
      , [ Const "eps"; _ ] ) ->
    true
  | Var _ | Const _ | Qid _ | App _ -> false

let tautological_condition bound = function
  | BoolCond term ->
    vars_subset (term_vars term) bound && prelude_true term
  | EqCond (left, right) ->
    vars_subset (term_vars left @ term_vars right) bound
    && ((prelude_true left && right = Const "true")
        || (left = Const "true" && prelude_true right))
  | MatchCond _ | MembershipCond _ -> false

let unbound_vars term bound =
  term_vars term
  |> List.filter (fun var -> not (List.mem var bound))

type equality_orientation =
  | Already_bound
  | Bind of term * term
  | Not_ready

let orient_equality constructor_op bound lhs rhs =
  let lhs_open = unbound_vars lhs bound in
  let rhs_open = unbound_vars rhs bound in
  match lhs_open, rhs_open with
  | [], [] -> Already_bound
  | _ :: _, []
    when Condition_pattern_certificate.is_pattern constructor_op lhs ->
    Bind (lhs, rhs)
  | [], _ :: _
    when Condition_pattern_certificate.is_pattern constructor_op rhs ->
    Bind (rhs, lhs)
  | _ -> Not_ready

let condition_bound_vars constructor_op bound = function
  | EqCond (lhs, rhs) ->
    (match orient_equality constructor_op bound lhs rhs with
    | Bind (pattern, _) -> add_vars (term_vars pattern) bound
    | Already_bound | Not_ready -> bound)
  | MembershipCond _ | BoolCond _ -> bound
  | MatchCond (pattern, _subject) ->
    if Condition_pattern_certificate.is_pattern constructor_op pattern then
      add_vars (term_vars pattern) bound
    else
      bound

let conditions_bound_vars
    ?(constructor_op = Condition_pattern_certificate.empty)
    initial_bound conditions =
  conditions
  |> List.fold_left (condition_bound_vars constructor_op) initial_bound

let is_match_pattern
    ?(constructor_op = Condition_pattern_certificate.empty) term =
  Condition_pattern_certificate.is_pattern constructor_op term

let source_constructor_certificate ctx =
  Condition_pattern_certificate.union
    Condition_pattern_certificate.imported
    (Condition_pattern_certificate.union
       (Condition_pattern_certificate.generated Prelude.statements)
       (Condition_pattern_certificate.source ctx))

let rule_condition_bound_vars
    ?(constructor_op = Condition_pattern_certificate.empty) bound = function
  | EqCondition condition -> condition_bound_vars constructor_op bound condition
  | RewriteCond (lhs, rhs) ->
    if vars_subset (term_vars lhs) bound
       && is_match_pattern ~constructor_op rhs then
      add_vars (term_vars rhs) bound
    else
      bound

let rule_conditions_bound_vars
    ?(constructor_op = Condition_pattern_certificate.empty)
    initial_bound conditions =
  conditions
  |> List.fold_left (rule_condition_bound_vars ~constructor_op) initial_bound

let add_unique_vars vars acc =
  vars
  |> List.fold_left
       (fun acc var -> if List.mem var acc then acc else var :: acc)
       acc

let external_vars_of_equality constructor_op bound required lhs rhs =
  match orient_equality constructor_op bound lhs rhs with
  | Bind (pattern, subject) ->
    ( add_vars (term_vars pattern) bound
    , add_unique_vars (unbound_vars subject bound) required )
  | Already_bound ->
    bound,
    add_unique_vars
      (unbound_vars lhs bound @ unbound_vars rhs bound)
      required
  | Not_ready ->
    bound,
    add_unique_vars
      (unbound_vars lhs bound @ unbound_vars rhs bound)
      required

let external_vars_of_term_after_conditions
    ?(constructor_op = Condition_pattern_certificate.empty)
    initial_bound term conditions =
  let bound, required =
    conditions
    |> List.fold_left
         (fun (bound, required) condition ->
           match condition with
           | EqCond (lhs, rhs) ->
             external_vars_of_equality
               constructor_op bound required lhs rhs
           | MatchCond (pattern, subject) ->
             let required =
               add_unique_vars (unbound_vars subject bound) required
             in
             if Condition_pattern_certificate.is_pattern constructor_op pattern then
               add_vars (term_vars pattern) bound, required
             else
               bound, add_unique_vars (unbound_vars pattern bound) required
           | MembershipCond (subject, _) | BoolCond subject ->
             bound, add_unique_vars (unbound_vars subject bound) required)
         (initial_bound, [])
  in
  add_unique_vars (unbound_vars term bound) required
  |> List.sort_uniq String.compare

let external_vars_of_conditions
    ?(constructor_op = Condition_pattern_certificate.empty)
    initial_bound conditions =
  let _bound, required =
    conditions
    |> List.fold_left
         (fun (bound, required) condition ->
           match condition with
           | EqCond (lhs, rhs) ->
             external_vars_of_equality
               constructor_op bound required lhs rhs
           | MatchCond (pattern, subject) ->
             let required =
               add_unique_vars (unbound_vars subject bound) required
             in
             if Condition_pattern_certificate.is_pattern constructor_op pattern then
               add_vars (term_vars pattern) bound, required
             else
               bound, add_unique_vars (unbound_vars pattern bound) required
           | MembershipCond (subject, _) | BoolCond subject ->
             bound, add_unique_vars (unbound_vars subject bound) required)
         (initial_bound, [])
  in
  required |> List.sort_uniq String.compare

let external_vars_of_rule_conditions
    ?(constructor_op = Condition_pattern_certificate.empty)
    initial_bound conditions =
  let add_condition (bound, required) = function
    | EqCondition condition ->
      (match condition with
      | EqCond (lhs, rhs) ->
        external_vars_of_equality
          constructor_op bound required lhs rhs
      | MatchCond (pattern, subject) ->
        let required = add_unique_vars (unbound_vars subject bound) required in
        if Condition_pattern_certificate.is_pattern constructor_op pattern then
          add_vars (term_vars pattern) bound, required
        else
          bound, add_unique_vars (unbound_vars pattern bound) required
      | MembershipCond (subject, _) | BoolCond subject ->
        bound, add_unique_vars (unbound_vars subject bound) required)
    | RewriteCond (lhs, rhs) ->
      let required = add_unique_vars (unbound_vars lhs bound) required in
      if vars_subset (term_vars lhs) bound
         && is_match_pattern ~constructor_op rhs then
        add_vars (term_vars rhs) bound, required
      else
        bound, add_unique_vars (unbound_vars rhs bound) required
  in
  conditions
  |> List.fold_left add_condition (initial_bound, [])
  |> snd
  |> List.sort_uniq String.compare

let split_bool_ands condition =
  let rec loop acc = function
    | BoolCond (App ("_and_", [ left; right ])) ->
      loop (loop acc (BoolCond right)) (BoolCond left)
    | condition -> condition :: acc
  in
  loop [] condition

let index_bound = function
  | BoolCond (App ("_<_", [ index; App ("len", [ sequence ]) ])) ->
    Some (sequence, index)
  | EqCond _ | MatchCond _ | MembershipCond _ | BoolCond _ -> None

let indexed_domain = function
  | BoolCond (App ("indexDefined", [ sequence; index ])) ->
    Some (sequence, index)
  | EqCond _ | MatchCond _ | MembershipCond _ | BoolCond _ -> None

(* [indexDefined(xs, i)] is defined in the prelude as [i < len(xs)].  Once
   the latter has been retained, the former is the same proposition. *)
let drop_implied_index_domains eq_condition conditions =
  let rec loop bounds retained = function
    | [] -> List.rev retained
    | item :: rest ->
      (match eq_condition item with
      | None -> loop bounds (item :: retained) rest
      | Some condition ->
        let implied =
          match indexed_domain condition with
          | Some domain -> List.mem domain bounds
          | None -> false
        in
        let bounds =
          match index_bound condition with
          | Some bound when not (List.mem bound bounds) -> bound :: bounds
          | Some _ | None -> bounds
        in
        if implied then loop bounds retained rest
        else loop bounds (item :: retained) rest)
  in
  loop [] [] conditions

let drop_implied_eq_domains =
  drop_implied_index_domains (fun condition -> Some condition)

let drop_implied_rule_domains =
  drop_implied_index_domains (function
    | EqCondition condition -> Some condition
    | RewriteCond _ -> None)

let bind_match_pattern bound pattern =
  add_vars (term_vars pattern) bound

let normalize_equality_term ~constructor_op bound lhs rhs =
  match orient_equality constructor_op bound lhs rhs with
  | Already_bound -> Some (bound, [ EqCond (lhs, rhs) ])
  | Bind (lhs, rhs) ->
    Some (bind_match_pattern bound lhs, [ MatchCond (lhs, rhs) ])
  | Not_ready -> None

let normalize_match_condition ~constructor_op bound pattern subject =
  if not (vars_subset (term_vars subject) bound) then
    None
  else if vars_subset (term_vars pattern) bound then
    Some (bound, [ EqCond (pattern, subject) ])
  else if is_match_pattern ~constructor_op pattern then
    Some (bind_match_pattern bound pattern, [ MatchCond (pattern, subject) ])
  else
    None

let normalize_ready ~constructor_op bound = function
  | condition when tautological_condition bound condition ->
    Some (bound, [])
  | MatchCond (pattern, subject) ->
    normalize_match_condition ~constructor_op bound pattern subject
  | EqCond (lhs, rhs) ->
    normalize_equality_term ~constructor_op bound lhs rhs
  | BoolCond term ->
    if vars_subset (term_vars term) bound then
      Some (bound, [ BoolCond term ])
    else
      None
  | MembershipCond (term, _) as condition ->
    if vars_subset (term_vars term) bound then
      Some (bound, [ condition ])
    else
      None

let normalize_binding_conditions
    ?(constructor_op = Condition_pattern_certificate.empty)
    lhs_terms conditions =
  let initial_bound =
    lhs_terms
    |> List.map term_vars
    |> List.concat
    |> List.sort_uniq String.compare
  in
  let rec take_ready bound prefix = function
    | [] -> None
    | condition :: rest ->
      (match normalize_ready ~constructor_op bound condition with
      | Some (bound, conditions) ->
        Some (bound, conditions, List.rev_append prefix rest)
      | None ->
        take_ready bound (condition :: prefix) rest)
  in
  let rec schedule bound acc pending =
    match take_ready bound [] pending with
    | Some (bound, ready_conditions, pending) ->
      schedule bound (List.rev_append ready_conditions acc) pending
    | None -> List.rev_append acc pending
  in
  conditions
  |> List.concat_map split_bool_ands
  |> schedule initial_bound []
  |> drop_implied_eq_domains

let normalize_rule_conditions
    ?(constructor_op = Condition_pattern_certificate.empty)
    ?(source_decisions = []) ?(domain_guards = [])
    lhs_terms conditions =
  let initial_bound =
    lhs_terms
    |> List.map term_vars
    |> List.concat
    |> List.sort_uniq String.compare
  in
  let flatten_condition = function
    | EqCondition condition ->
      split_bool_ands condition |> List.map (fun condition -> EqCondition condition)
    | RewriteCond _ as condition -> [ condition ]
  in
  let source_decisions = List.concat_map flatten_condition source_decisions in
  let domain_guards = List.concat_map flatten_condition domain_guards in
  conditions
  |> List.concat_map flatten_condition
  |> fun pending ->
  let normalize_rule_ready bound = function
    | EqCondition condition ->
      (match normalize_ready ~constructor_op bound condition with
      | Some (bound, conditions) ->
        Some (bound, List.map (fun condition -> EqCondition condition) conditions)
      | None -> None)
    | RewriteCond (lhs, rhs) as condition ->
      if vars_subset (term_vars lhs) bound
         && is_match_pattern ~constructor_op rhs then
        Some (add_vars (term_vars rhs) bound, [ condition ])
      else
        None
  in
  let lhs_ops =
    lhs_terms
    |> List.filter_map (function App (op, _) -> Some op | _ -> None)
    |> List.sort_uniq String.compare
  in
  let self_recursive = function
    | RewriteCond (App (op, _), _) -> List.mem op lhs_ops
    | EqCondition _ | RewriteCond _ -> false
  in
  let primitive_term bound = function
    | Var name -> List.mem name bound
    | Const _ | Qid _ -> true
    | App _ -> false
  in
  let rec total_bool_term bound = function
    | App (("_==_" | "_=/=_"), [ left; right ]) ->
      primitive_term bound left && primitive_term bound right
    | App (("_and_" | "_or_"), [ left; right ]) ->
      total_bool_term bound left && total_bool_term bound right
    | App ("not_", [ term ]) -> total_bool_term bound term
    | Const ("true" | "false") -> true
    | Var _ | Const _ | Qid _ | App _ -> false
  in
  let total_bool_guard bound = function
    | EqCondition (BoolCond term) -> total_bool_term bound term
    | EqCondition (EqCond _ | MatchCond _ | MembershipCond _) | RewriteCond _ ->
      false
  in
  let rec take_ready bound prefix = function
    | [] -> None
    | condition :: rest ->
      (match normalize_rule_ready bound condition with
      | Some (bound, conditions) ->
        Some (condition, bound, conditions, prefix, rest)
      | None -> take_ready bound (condition :: prefix) rest)
  in
  let rec take_progress_guard bound prefix = function
    | [] -> None
    | condition :: rest when total_bool_guard bound condition ->
      (match normalize_rule_ready bound condition with
      | Some (next_bound, conditions) when next_bound = bound ->
        Some (condition, conditions, List.rev_append prefix rest)
      | Some _ | None -> None)
    | condition :: _ when List.mem condition source_decisions -> None
    | condition :: rest ->
      take_progress_guard bound (condition :: prefix) rest
  in
  let source_ready bound condition =
    List.mem condition source_decisions
    && (match normalize_rule_ready bound condition with
        | Some (next_bound, _) ->
          next_bound = bound
          || (match condition with
              | RewriteCond _ -> true
              | EqCondition _ -> false)
        | None -> false)
  in
  let ready_domain_guard bound conditions =
    List.exists
      (fun condition ->
        match normalize_rule_ready bound condition with
        | Some _ -> true
        | None -> false)
      conditions
  in
  let ready_rewrite bound = function
    | RewriteCond _ as condition -> Option.is_some (normalize_rule_ready bound condition)
    | EqCondition _ -> false
  in
  let rec has_progress_exception bound = function
    | [] -> false
    | condition :: rest when self_recursive condition && ready_rewrite bound condition ->
      Option.is_some (take_progress_guard bound [] rest)
    | _ :: rest -> has_progress_exception bound rest
  in
  let rec take_source_decision bound skipped selected = function
    | [] -> None
    | condition :: rest when List.mem condition source_decisions ->
      (match normalize_rule_ready bound condition with
      | Some _ when self_recursive condition ->
        (match take_progress_guard bound [] rest with
        | Some (guard, guard_conditions, rest) ->
          Some
            ( guard
            , bound
            , List.rev_append selected guard_conditions
            , List.rev_append skipped (condition :: rest) )
        | None -> None)
      | Some _
        when ready_domain_guard bound skipped
             && (match condition with
                 | RewriteCond _ -> true
                 | EqCondition _ -> false) ->
        None
      | Some (next_bound, conditions)
        when next_bound = bound
             || (match condition with
                 | RewriteCond _ -> true
                 | EqCondition _ -> false) ->
        Some
          ( condition
          , next_bound
          , List.rev_append selected conditions
          , List.rev_append skipped rest )
      | Some _ | None -> None)
    | condition :: rest
      when Option.is_some (normalize_rule_ready bound condition)
           && List.exists (ready_rewrite bound) rest
           && not (has_progress_exception bound rest) ->
      None
    | condition :: rest when List.mem condition domain_guards ->
      (match normalize_rule_ready bound condition with
      | Some (next_bound, _) when next_bound <> bound
          && List.exists (source_ready bound) rest ->
        take_source_decision bound (condition :: skipped) selected rest
      | Some (next_bound, conditions) when next_bound <> bound ->
        take_source_decision next_bound skipped
          (List.rev_append conditions selected) rest
      | Some _ | None ->
        take_source_decision bound (condition :: skipped) selected rest)
    | _ -> None
  in
  (* Scheduling is stable: choose the least source-ready condition, considering
     later conditions only while an earlier one has unbound inputs.  The sole
     progress exception is a structurally total primitive Bool guard before a
     ready self-recursive rewrite.  Moving that guard does not move the rewrite
     with it.  A rewrite never crosses an earlier ready condition, independent
     of whether that condition also appears in a role list.
     This is a narrow validated-ingress optimization, not arbitrary premise
     reordering. *)
  let take_ready bound pending =
    match take_source_decision bound [] [] pending with
    | Some ready -> Some ready
    | None ->
      (match take_ready bound [] pending with
      | None -> None
      | Some (condition, next_bound, conditions, prefix, rest) ->
        let ready () =
          Some
            ( condition
            , next_bound
            , conditions
            , List.rev_append prefix rest )
        in
        if not (self_recursive condition) then ready ()
        else
          match take_ready bound [] rest with
          | Some (guard, guard_bound, guards, guard_prefix, guard_rest)
            when total_bool_guard bound guard ->
            Some
              ( guard
              , guard_bound
              , guards
              , List.rev_append prefix
                  (condition :: List.rev_append guard_prefix guard_rest) )
          | Some _ | None -> ready ())
  in
  let rec schedule bound acc pending =
    match take_ready bound pending with
    | Some (_, bound, ready_conditions, pending) ->
      schedule bound (List.rev_append ready_conditions acc) pending
    | None -> List.rev_append acc pending
  in
  schedule initial_bound [] pending
  |> drop_implied_rule_domains
