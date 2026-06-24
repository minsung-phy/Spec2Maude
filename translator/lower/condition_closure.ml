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

let condition_bound_vars bound = function
  | EqCond _ | MembershipCond _ | BoolCond _ -> bound
  | MatchCond (pattern, _subject) -> add_vars (term_vars pattern) bound

let conditions_bound_vars initial_bound conditions =
  conditions |> List.fold_left condition_bound_vars initial_bound

let string_has_prefix ~prefix text =
  let prefix_len = String.length prefix in
  String.length text >= prefix_len
  && String.sub text 0 prefix_len = prefix

let string_for_all predicate text =
  let rec loop index =
    index = String.length text || (predicate text.[index] && loop (index + 1))
  in
  loop 0

let source_constructor_name name =
  let valid_char = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  name <> ""
  && string_for_all valid_char name
  && not (string_has_prefix ~prefix:"def" name)
  && not (string_has_prefix ~prefix:"helper" name)
  && not (string_has_prefix ~prefix:"proj." name)

let non_pattern_op_name = function
  | "typecheck"
  | "typecheckSeq"
  | "typecheckOptSeq"
  | "typecheckSeqOpt"
  | "typecheckNestedSeq"
  | "isOpt"
  | "allOpt"
  | "allLen"
  | "len"
  | "drop"
  | "splice"
  | "contains"
  | "isTrue"
  | "value"
  | "index"
  | "slice"
  | "natOfInt"
  | "intOfRat"
  | "natOfRat"
  | "ratIsInt"
  | "modNat"
  | "modInt"
  | "_+_"
  | "_-_"
  | "_*_"
  | "_/_"
  | "_^_"
  | "_==_"
  | "_=/=_"
  | "_<_"
  | "_<=_"
  | "_>_"
  | "_>=_"
  | "_and_"
  | "_or_"
  | "not_" -> true
  | name -> String.length name > 0 && name.[0] = '_'

let pattern_op_name = function
  | "eps"
  | "_ _"
  | "bool"
  | "rat"
  | "float"
  | "text"
  | "seq"
  | "tuple"
  | "{_}"
  | "_;_"
  | "item" -> true
  | name ->
    (String.contains name '.' && not (string_has_prefix ~prefix:"proj." name))
    || string_has_prefix ~prefix:"rec-" name
    || ((not (non_pattern_op_name name)) && source_constructor_name name)

let rec is_match_pattern = function
  | Var _ | Const _ | Qid _ -> true
  | App (name, args) ->
    pattern_op_name name && List.for_all is_match_pattern args

let rule_condition_bound_vars bound = function
  | EqCondition condition -> condition_bound_vars bound condition
  | RewriteCond (_lhs, rhs) ->
    if is_match_pattern rhs then
      add_vars (term_vars rhs) bound
    else
      bound

let rule_conditions_bound_vars initial_bound conditions =
  conditions |> List.fold_left rule_condition_bound_vars initial_bound

let unbound_vars term bound =
  term_vars term
  |> List.filter (fun var -> not (List.mem var bound))

let add_unique_vars vars acc =
  vars
  |> List.fold_left
       (fun acc var -> if List.mem var acc then acc else var :: acc)
       acc

let vars_text vars =
  vars
  |> List.sort_uniq String.compare
  |> String.concat ", "

let external_vars_of_term_after_conditions initial_bound term conditions =
  let bound, required =
    conditions
    |> List.fold_left
         (fun (bound, required) condition ->
           match condition with
           | EqCond (lhs, rhs) ->
             bound,
             add_unique_vars
               (unbound_vars lhs bound @ unbound_vars rhs bound)
               required
           | MatchCond (pattern, subject) ->
             let required =
               add_unique_vars (unbound_vars subject bound) required
             in
             add_vars (term_vars pattern) bound, required
           | MembershipCond (subject, _) | BoolCond subject ->
             bound, add_unique_vars (unbound_vars subject bound) required)
         (initial_bound, [])
  in
  add_unique_vars (unbound_vars term bound) required
  |> List.sort_uniq String.compare

let external_vars_of_conditions initial_bound conditions =
  let _bound, required =
    conditions
    |> List.fold_left
         (fun (bound, required) condition ->
           match condition with
           | EqCond (lhs, rhs) ->
             bound,
             add_unique_vars
               (unbound_vars lhs bound @ unbound_vars rhs bound)
               required
           | MatchCond (pattern, subject) ->
             let required =
               add_unique_vars (unbound_vars subject bound) required
             in
             add_vars (term_vars pattern) bound, required
           | MembershipCond (subject, _) | BoolCond subject ->
             bound, add_unique_vars (unbound_vars subject bound) required)
         (initial_bound, [])
  in
  required |> List.sort_uniq String.compare

let condition_admissible_bound bound = function
  | EqCond (lhs, rhs) ->
    let vars = term_vars lhs @ term_vars rhs |> List.sort_uniq String.compare in
    if vars_subset vars bound then Some bound else None
  | MatchCond (pattern, subject) ->
    if is_match_pattern pattern && vars_subset (term_vars subject) bound then
      Some (add_vars (term_vars pattern) bound)
    else
      None
  | MembershipCond (subject, _) | BoolCond subject ->
    let vars = term_vars subject in
    if vars_subset vars bound then Some bound else None

let conditions_admissible_bound initial_bound conditions =
  conditions
  |> List.fold_left
       (fun bound_opt condition ->
         match bound_opt with
         | None -> None
         | Some bound -> condition_admissible_bound bound condition)
       (Some initial_bound)

let helper_call_admissible_after_conditions bound guards helper_args =
  match conditions_admissible_bound bound guards with
  | None -> false
  | Some bound_after ->
    helper_args
    |> List.map term_vars
    |> List.concat
    |> List.sort_uniq String.compare
    |> fun vars -> vars_subset vars bound_after

let split_bool_ands condition =
  let rec loop = function
    | BoolCond (App ("_and_", [ left; right ])) ->
      loop (BoolCond left) @ loop (BoolCond right)
    | condition -> [ condition ]
  in
  loop condition

let bind_match_pattern bound pattern =
  add_vars (term_vars pattern) bound

let normalize_equality_term bound lhs rhs =
  let lhs_unbound = unbound_vars lhs bound in
  let rhs_unbound = unbound_vars rhs bound in
  match lhs_unbound, rhs_unbound with
  | [], [] -> Some (bound, [ EqCond (lhs, rhs) ])
  | _ :: _, [] when vars_subset (term_vars rhs) bound && is_match_pattern lhs ->
    Some (bind_match_pattern bound lhs, [ MatchCond (lhs, rhs) ])
  | [], _ :: _ when vars_subset (term_vars lhs) bound && is_match_pattern rhs ->
    Some (bind_match_pattern bound rhs, [ MatchCond (rhs, lhs) ])
  | _ -> None

let normalize_match_condition bound pattern subject =
  if not (vars_subset (term_vars subject) bound) then
    None
  else if vars_subset (term_vars pattern) bound then
    Some (bound, [ EqCond (pattern, subject) ])
  else if is_match_pattern pattern then
    Some (bind_match_pattern bound pattern, [ MatchCond (pattern, subject) ])
  else
    None

let normalize_ready bound = function
  | MatchCond (pattern, subject) ->
    normalize_match_condition bound pattern subject
  | EqCond (lhs, Var name)
    when (not (List.mem name bound)) && vars_subset (term_vars lhs) bound ->
    Some (name :: bound, [ MatchCond (Var name, lhs) ])
  | EqCond (Var name, rhs)
    when (not (List.mem name bound)) && vars_subset (term_vars rhs) bound ->
    Some (name :: bound, [ MatchCond (Var name, rhs) ])
  | EqCond (lhs, rhs) ->
    normalize_equality_term bound lhs rhs
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

let normalize_binding_conditions lhs_terms conditions =
  let initial_bound =
    lhs_terms
    |> List.map term_vars
    |> List.concat
    |> List.sort_uniq String.compare
  in
  let rec take_ready bound prefix = function
    | [] -> None
    | condition :: rest ->
      (match normalize_ready bound condition with
      | Some (bound, conditions) ->
        Some (bound, conditions, List.rev_append prefix rest)
      | None ->
        take_ready bound (condition :: prefix) rest)
  in
  let rec schedule bound acc pending =
    match take_ready bound [] pending with
    | Some (bound, ready_conditions, pending) ->
      schedule bound (acc @ ready_conditions) pending
    | None ->
      acc @ pending
  in
  conditions
  |> List.concat_map split_bool_ands
  |> schedule initial_bound []

let normalize_rule_conditions lhs_terms conditions =
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
  conditions
  |> List.concat_map flatten_condition
  |> fun pending ->
  let normalize_rule_ready bound = function
    | EqCondition condition ->
      (match normalize_ready bound condition with
      | Some (bound, conditions) ->
        Some (bound, List.map (fun condition -> EqCondition condition) conditions)
      | None -> None)
    | RewriteCond (lhs, rhs) as condition ->
      if vars_subset (term_vars lhs) bound then
        Some (add_vars (term_vars rhs) bound, [ condition ])
      else
        None
  in
  let rec take_ready bound prefix = function
    | [] -> None
    | condition :: rest ->
      (match normalize_rule_ready bound condition with
      | Some (bound, conditions) ->
        Some (bound, conditions, List.rev_append prefix rest)
      | None -> take_ready bound (condition :: prefix) rest)
  in
  let rec schedule bound acc pending =
    match take_ready bound [] pending with
    | Some (bound, ready_conditions, pending) ->
      schedule bound (acc @ ready_conditions) pending
    | None -> acc @ pending
  in
  schedule initial_bound [] pending

let unsupported ?suggestion ?source_echo ~ctx ~origin ~constructor ~reason () =
  Diagnostics.make
    ?suggestion
    ?source_echo
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ()

let all_vars_bound bound term =
  vars_subset (term_vars term) bound

let ceq_admissibility_diagnostics ctx origin lhs rhs conditions =
  let mk_diag ?suggestion constructor reason =
    unsupported
      ~ctx
      ~origin
      ~constructor
      ~reason
      ~suggestion:
        (Option.value
           suggestion
           ~default:
             "Bind variables through the statement lhs or an admissible earlier matching condition before emitting this equation")
      ()
  in
  let inverse_diag index role missing =
    mk_diag
      "DecD/inverse-binding-needed"
      (Printf.sprintf
         "%s would need to solve variable(s) through an inverse-like equality before emitting this equation: %s"
         (Printf.sprintf "condition %d %s" index role)
         (vars_text missing))
      ~suggestion:
        "Leave this DecD clause Unsupported until a source-driven deterministic/invertible binding rule or builtin obligation is available; do not infer it from names"
  in
  let condition_diag index role missing =
    match missing with
    | [] -> []
    | _ :: _ ->
      [ mk_diag
          "MaudeRegistry/ceq-condition-admissibility"
          (Printf.sprintf
             "condition %d uses variable(s) before they are bound in %s: %s"
             index
             role
             (vars_text missing))
      ]
  in
  let dependent_inverse_diag index role missing inverse_needed =
    let inverse_missing =
      missing |> List.filter (fun var -> List.mem var inverse_needed)
    in
    let ordinary_missing =
      missing |> List.filter (fun var -> not (List.mem var inverse_needed))
    in
    (match inverse_missing with
    | [] -> []
    | _ :: _ ->
      [ mk_diag
          "DecD/inverse-binding-needed"
          (Printf.sprintf
             "%s depends on variable(s) whose only known introduction in this clause would require inverse-like binding: %s"
             role
             (vars_text inverse_missing))
          ~suggestion:
            "Keep the source construct Unsupported until inverse/deterministic binding is implemented source-driven"
      ])
    @ condition_diag index role ordinary_missing
  in
  let inverse_dependent_binding_diag index role vars dependencies =
    match vars with
    | [] -> []
    | _ :: _ ->
      [ mk_diag
          "DecD/inverse-binding-needed"
          (Printf.sprintf
             "%s would introduce variable(s) whose defining side depends on inverse-like binding: %s; dependency: %s"
             (Printf.sprintf "condition %d %s" index role)
             (vars_text vars)
             (vars_text dependencies))
          ~suggestion:
            "Keep this DecD clause Unsupported until the dependency can be solved by a source-driven deterministic/invertible rule"
      ]
  in
  let rec check_conditions index bound inverse_needed diagnostics = function
    | [] -> bound, inverse_needed, diagnostics
    | condition :: rest ->
      let bound, inverse_needed, diagnostics =
        match condition with
        | EqCond (lhs, rhs) ->
          let lhs_missing = unbound_vars lhs bound in
          let rhs_missing = unbound_vars rhs bound in
          let missing = lhs_missing @ rhs_missing in
          let inverse_missing =
            if
              lhs_missing <> []
              && all_vars_bound bound rhs
              && not (is_match_pattern lhs)
            then
              lhs_missing
            else if
              rhs_missing <> []
              && all_vars_bound bound lhs
              && not (is_match_pattern rhs)
            then
              rhs_missing
            else
              []
          in
          let lhs_inverse_dependencies =
            lhs_missing |> List.filter (fun var -> List.mem var inverse_needed)
          in
          let rhs_inverse_dependencies =
            rhs_missing |> List.filter (fun var -> List.mem var inverse_needed)
          in
          let lhs_ordinary_missing =
            lhs_missing
            |> List.filter (fun var -> not (List.mem var inverse_needed))
          in
          let rhs_ordinary_missing =
            rhs_missing
            |> List.filter (fun var -> not (List.mem var inverse_needed))
          in
          let inverse_dependent_missing, inverse_dependencies =
            if
              lhs_ordinary_missing <> []
              && rhs_inverse_dependencies <> []
              && rhs_ordinary_missing = []
              && is_match_pattern lhs
            then
              lhs_ordinary_missing, rhs_inverse_dependencies
            else if
              rhs_ordinary_missing <> []
              && lhs_inverse_dependencies <> []
              && lhs_ordinary_missing = []
              && is_match_pattern rhs
            then
              rhs_ordinary_missing, lhs_inverse_dependencies
            else
              [], []
          in
          let missing_for_diagnostics =
            missing
            |> List.filter (fun var ->
              not (List.mem var inverse_dependent_missing))
          in
          let diagnostics =
            if inverse_missing <> [] then
              diagnostics
              @ [ inverse_diag index "equation condition" inverse_missing ]
              @ dependent_inverse_diag
                  index
                  "equation condition"
                  (missing_for_diagnostics
                   |> List.filter (fun var -> not (List.mem var inverse_missing)))
                  inverse_needed
            else
              diagnostics
              @ dependent_inverse_diag index "equation" missing_for_diagnostics inverse_needed
              @ inverse_dependent_binding_diag
                  index
                  "equation condition"
                  inverse_dependent_missing
                  inverse_dependencies
          in
          bound,
          add_vars
            (inverse_missing @ inverse_dependent_missing)
            inverse_needed,
          diagnostics
        | MatchCond (pattern, subject) ->
          let missing = unbound_vars subject bound in
          let pattern_diagnostics =
            if is_match_pattern pattern then
              []
            else
              [ mk_diag
                  "DecD/match-condition-pattern"
                  "matching condition lhs is not a Maude pattern, so it cannot introduce variables soundly"
                  ~suggestion:
                    "Lower the source lhs to a constructor/variable pattern before emitting a Maude matching condition"
              ]
          in
          let bound =
            if pattern_diagnostics = [] then
              add_vars (term_vars pattern) bound
            else
              bound
          in
          bound,
          inverse_needed,
          diagnostics
          @ pattern_diagnostics
          @ dependent_inverse_diag index "matching subject" missing inverse_needed
        | MembershipCond (term, _) ->
          let missing = unbound_vars term bound in
          let inverse_missing =
            missing |> List.filter (fun var -> List.mem var inverse_needed)
          in
          let inverse_dependent_missing =
            if inverse_missing = [] then
              []
            else
              missing |> List.filter (fun var -> not (List.mem var inverse_needed))
          in
          let missing_for_diagnostics =
            missing
            |> List.filter (fun var ->
              not (List.mem var inverse_dependent_missing))
          in
          bound,
          add_vars inverse_dependent_missing inverse_needed,
          diagnostics
          @ dependent_inverse_diag index "membership term" missing_for_diagnostics inverse_needed
          @ inverse_dependent_binding_diag
              index
              "membership term"
              inverse_dependent_missing
              inverse_missing
        | BoolCond term ->
          let missing = unbound_vars term bound in
          let inverse_missing =
            missing |> List.filter (fun var -> List.mem var inverse_needed)
          in
          let inverse_dependent_missing =
            if inverse_missing = [] then
              []
            else
              missing |> List.filter (fun var -> not (List.mem var inverse_needed))
          in
          let missing_for_diagnostics =
            missing
            |> List.filter (fun var ->
              not (List.mem var inverse_dependent_missing))
          in
          bound,
          add_vars inverse_dependent_missing inverse_needed,
          diagnostics
          @ dependent_inverse_diag index "Bool condition" missing_for_diagnostics inverse_needed
          @ inverse_dependent_binding_diag
              index
              "Bool condition"
              inverse_dependent_missing
              inverse_missing
      in
      check_conditions (index + 1) bound inverse_needed diagnostics rest
  in
  let bound, inverse_needed, diagnostics =
    check_conditions 1 (term_vars lhs) [] [] conditions
  in
  match unbound_vars rhs bound with
  | [] -> diagnostics
  | missing ->
    let inverse_missing =
      missing |> List.filter (fun var -> List.mem var inverse_needed)
    in
    let ordinary_missing =
      missing |> List.filter (fun var -> not (List.mem var inverse_needed))
    in
    diagnostics
    @ (match inverse_missing with
      | [] -> []
      | _ :: _ ->
        [ mk_diag
            "DecD/inverse-binding-needed"
            ("statement rhs depends on variable(s) whose only known introduction in this clause would require inverse-like binding: "
             ^ vars_text inverse_missing)
            ~suggestion:
              "Keep this DecD clause Unsupported until inverse/deterministic binding is implemented source-driven; do not emit a ceq that uses these variables before binding them"
        ])
    @ (match ordinary_missing with
      | [] -> []
      | _ :: _ ->
        [ mk_diag
            "MaudeRegistry/ceq-condition-admissibility"
            ("statement rhs uses variable(s) before they are bound by lhs or conditions: "
             ^ vars_text ordinary_missing)
        ])

let crl_admissibility_diagnostics ctx origin lhs rhs conditions =
  let mk_diag constructor reason =
    unsupported
      ~ctx
      ~origin
      ~constructor
      ~reason
      ~suggestion:
        "Bind variables through the rule lhs or an admissible earlier matching/rewrite condition before emitting this rewrite rule"
      ()
  in
  let condition_diag index role missing =
    match missing with
    | [] -> []
    | _ :: _ ->
      [ mk_diag
          "MaudeRegistry/crl-condition-admissibility"
          (Printf.sprintf
             "condition %d uses variable(s) before they are bound in %s: %s"
             index
             role
             (vars_text missing))
      ]
  in
  let rec check_conditions index bound diagnostics = function
    | [] -> bound, diagnostics
    | condition :: rest ->
      let bound, diagnostics =
        match condition with
        | EqCondition (EqCond (condition_lhs, condition_rhs)) ->
          bound,
          diagnostics
          @ condition_diag index "equation lhs" (unbound_vars condition_lhs bound)
          @ condition_diag index "equation rhs" (unbound_vars condition_rhs bound)
        | EqCondition (MatchCond (pattern, subject)) ->
          let subject_missing = unbound_vars subject bound in
          let pattern_diags =
            if is_match_pattern pattern then
              []
            else
              [ mk_diag
                  "MaudeRegistry/crl-condition-admissibility"
                  (Printf.sprintf
                     "condition %d matching lhs is not a Maude pattern, so it cannot introduce variables soundly"
                     index)
              ]
          in
          let bound =
            if subject_missing = [] && pattern_diags = [] then
              add_vars (term_vars pattern) bound
            else
              bound
          in
          bound,
          diagnostics
          @ condition_diag index "matching subject" subject_missing
          @ pattern_diags
        | EqCondition (MembershipCond (term, _)) ->
          bound,
          diagnostics
          @ condition_diag index "membership term" (unbound_vars term bound)
        | EqCondition (BoolCond term) ->
          bound,
          diagnostics
          @ condition_diag index "Bool condition" (unbound_vars term bound)
        | RewriteCond (condition_lhs, condition_rhs) ->
          let lhs_missing = unbound_vars condition_lhs bound in
          let rhs_pattern_diags =
            if is_match_pattern condition_rhs then
              []
            else
              [ mk_diag
                  "MaudeRegistry/crl-condition-admissibility"
                  (Printf.sprintf
                     "condition %d rewrite rhs is not a Maude pattern, so it cannot introduce witness variables soundly"
                     index)
              ]
          in
          let bound =
            if lhs_missing = [] && rhs_pattern_diags = [] then
              add_vars (term_vars condition_rhs) bound
            else
              bound
          in
          bound,
          diagnostics
          @ condition_diag index "rewrite lhs" lhs_missing
          @ rhs_pattern_diags
      in
      check_conditions (index + 1) bound diagnostics rest
  in
  let bound, diagnostics =
    check_conditions 1 (term_vars lhs) [] conditions
  in
  match unbound_vars rhs bound with
  | [] -> diagnostics
  | missing ->
    diagnostics
    @ [ mk_diag
          "MaudeRegistry/crl-condition-admissibility"
          ("statement rhs uses variable(s) before they are bound by lhs or conditions: "
           ^ vars_text missing)
      ]
