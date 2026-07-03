open Il.Ast
open Maude_ir
open Util.Source

open Reld_common

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
      | Some (seen, conditions) -> loop seen (List.rev_append conditions acc) (subjects, patterns))
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

let condition_bool_term = function
  | BoolCond term -> Some term
  | EqCond (left, right) -> Some (App ("_==_", [ left; right ]))
  | MatchCond _ | MembershipCond _ -> None

let rec or_terms = function
  | [] -> None
  | [ term ] -> Some term
  | term :: terms ->
    (match or_terms terms with
    | None -> Some term
    | Some rest -> Some (App ("_or_", [ term; rest ])))

let direct_complement_condition current_terms predecessor_terms conditions =
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
      let rec collect_negated acc = function
        | [] -> Some (List.rev acc)
        | condition :: rest ->
          (match complement_atom bound condition with
          | Skip_guard -> collect_negated acc rest
          | Negated condition -> collect_negated (condition :: acc) rest
          | Blocked -> None)
      in
      match collect_negated [] conditions with
      | None -> None
      | Some negated_conditions ->
        let bool_terms =
          (head_mismatches @ negated_conditions)
          |> List.filter_map condition_bool_term
        in
        match or_terms bool_terms with
        | None -> None
        | Some term -> Some (EqCondition (BoolCond term)))

let without_else_premises prems =
  prems
  |> List.filter (fun prem ->
    match prem.it with
    | ElsePr -> false
    | _ -> true)

type enabledness_info =
  { helper_name : string
  ; output : output
  ; complement_conditions : Maude_ir.rule_condition list
  }

type enabledness_result =
  | Not_applicable
  | Enabledness of enabledness_info

let helper_name relation_id rule_id index =
  "enabled-" ^ rule_label relation_id rule_id index

let translate_helper
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    _input_sorts
    current_lhs_terms
    index
    rule =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id.it rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      Enabledness
        { helper_name = helper_name relation_id rule_id index
        ; output = { empty with diagnostics = hint_diags @ marker_diags }
        ; complement_conditions = []
        }
    else
      let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
      let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
      let expected_typs = input_typs @ output_typs in
      let components_opt, arity_diags =
        exp_components_match
          ctx
          origin
          "RelD/ElsePr/enabledness/arity"
          expected_typs
          exp
      in
      (match components_opt with
      | None ->
        Enabledness
          { helper_name = helper_name relation_id rule_id index
          ; output = { empty with diagnostics = arity_diags }
          ; complement_conditions = []
          }
      | Some components ->
        let input_count = List.length input_typs in
        let rec split n left right =
          if n = 0 then List.rev left, right
          else
            match right with
            | [] -> List.rev left, []
            | item :: rest -> split (n - 1) (item :: left) rest
        in
        let input_exps, _output_exps = split input_count [] components in
        let seed = helper_name relation_id rule_id index in
        let env, var_decls, bind_diags =
          translate_rule_binds ctx origin seed binds
        in
        let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
          lower_pattern_components ctx env origin input_exps
        in
        (match lhs_terms_opt with
        | Some lhs_terms when terms_match_general current_lhs_terms lhs_terms ->
          let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
          let premise_result =
            Premise_translate.translate_premises
              ~allow_runtime_search:true
              ctx
              env
              ~bound_conditions:lhs_guards
              ~bound_terms:lhs_terms
              origin
              (without_else_premises prems)
          in
          let helper_name = helper_name relation_id rule_id index in
          if premise_result.rule_conditions = [] then
            (match
               direct_complement_condition
                 current_lhs_terms
                 lhs_terms
                 premise_result.eq_conditions
             with
            | Some complement_condition ->
              Enabledness
                { helper_name
                ; output =
                    { statements = var_decls
                    ; diagnostics =
                        hint_diags
                        @ bind_diags @ arity_diags @ lhs_diags
                        @ premise_result.diagnostics
                    }
                ; complement_conditions = [ complement_condition ]
                }
            | None ->
              Enabledness
                { helper_name
                ; output =
                    { statements = var_decls
                    ; diagnostics =
                        hint_diags
                        @ bind_diags @ arity_diags @ lhs_diags
                        @ premise_result.diagnostics
                        @ [ unsupported
                              ~ctx
                              ~origin
                              ~constructor:"RelD/ElsePr/enabledness/non-total-bool"
                              ~source_echo:(Il.Print.string_of_rule rule)
                              ~reason:
                                "otherwise predecessor enabledness has only positive equational conditions, but the translator could not derive a source-level Bool complement from the predecessor head and premises"
                              ~suggestion:
                                "Implement a source-derived total enabledness decision or a documented direct complement for this premise shape before lowering the otherwise branch"
                              ()
                          ]
                    }
                ; complement_conditions = []
                })
          else if premise_result.runtime_truth_search_requests <> [] then
            Enabledness
              { helper_name
              ; output =
                  { statements = var_decls
                  ; diagnostics =
                      hint_diags
                      @ bind_diags @ arity_diags @ lhs_diags
                      @ premise_result.diagnostics
                      @ [ unsupported
                            ~ctx
                            ~origin
                            ~constructor:"RelD/ElsePr/enabledness/runtime-truth-false"
                            ~source_echo:(Il.Print.string_of_rule rule)
                            ~reason:
                              "enabledness complement depends on runtime predicate truth search, but runtimeTruthFalse/no-hit refutation is not source-complete yet"
                            ~suggestion:
                              "Leave this otherwise complement Unsupported until runtime truth false/no-hit materialization is all-or-nothing and source-complete"
                            ()
                        ]
                  }
              ; complement_conditions = []
              }
          else
            Enabledness
              { helper_name
              ; output =
                  { statements = var_decls
                  ; diagnostics =
                      hint_diags
                      @ bind_diags @ arity_diags @ lhs_diags
                      @ premise_result.diagnostics
                      @ [ unsupported
                            ~ctx
                            ~origin
                            ~constructor:"RelD/ElsePr/enabledness/rewrite-condition"
                            ~source_echo:(Il.Print.string_of_rule rule)
                            ~reason:
                              "enabledness helper for an otherwise predecessor contains rewrite conditions that are not runtime truth-search decisions"
                            ~suggestion:
                              "Keep this otherwise complement Unsupported until this rewrite-dependent premise shape has a source-complete enabledness decision helper"
                            ()
                        ]
                  }
              ; complement_conditions = []
              }
        | Some _ -> Not_applicable
        | None ->
          Enabledness
            { helper_name = helper_name relation_id rule_id index
            ; output =
                { statements = var_decls
                ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
                }
            ; complement_conditions = []
            }))

let complement
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    shape
    input_sorts
    origin
    current_lhs_terms
    previous_rules =
  let enabledness =
    previous_rules
    |> List.mapi (fun index rule ->
      translate_helper
        ctx
        rel_origin
        relation_id
        relation_kind
        relation_mixop
        shape
        input_sorts
        current_lhs_terms
        (index + 1)
        rule)
  in
  let applicable =
    enabledness
    |> List.filter_map (function
      | Not_applicable -> None
      | Enabledness result -> Some result)
  in
  match applicable with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"RelD/RuleD/ElsePr/complement"
            ~reason:
              "source otherwise rule has no earlier rule with the same relation input skeleton, so the translator cannot derive a source enabledness complement"
            ~suggestion:
              "Keep this ElsePr Unsupported until rule grouping/preprocessing can prove the relevant predecessor rules"
            ()
        ]
    },
    []
  | _ ->
    let statements =
      applicable
      |> List.map (fun result -> result.output.statements)
      |> List.concat
    in
    let diagnostics =
      applicable
      |> List.map (fun result -> result.output.diagnostics)
      |> List.concat
    in
    let has_blocking = has_fatal diagnostics in
    let statements = if has_blocking then [] else statements in
    let complement_conditions =
      if has_blocking then
        []
      else
        applicable
        |> List.map (fun result -> result.complement_conditions)
        |> List.concat
    in
    let diagnostics =
      if has_blocking then
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"RelD/RuleD/ElsePr/complement-unsupported"
            ~reason:
              "at least one predecessor rule in this otherwise group needs enabledness conditions that are not safely expressible by the current source-derived helper slice; the predecessor rule itself reports the blocking premise"
            ~suggestion:
              "Leave this ElsePr Unsupported until the blocking predecessor premise shape has a documented helper"
            ()
        ]
      else
        diagnostics
    in
    { statements; diagnostics }, complement_conditions
