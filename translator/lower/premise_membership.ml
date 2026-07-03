open Il.Ast
open Maude_ir
open Util.Source

(* Binding-only lowering for IfPr(MemE(left, right)).
   Ordinary membership checks stay in Premise_translate so the MemE
   constructor remains visible at the dispatcher boundary. *)

let app name args =
  App (name, args)

let sequence_concat left right =
  app "_ _" [ left; right ]

let pattern_has_fatal (result : Expr_translate.pattern_result) =
  List.exists Diagnostics.is_fatal result.pattern_diagnostics

let result_has_fatal (result : Expr_translate.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let pattern_is_unbound bound_vars (result : Expr_translate.pattern_result) =
  match result.pattern_term with
  | None -> false
  | Some term ->
    not (Condition_closure.vars_subset (Condition_closure.term_vars term) bound_vars)

let unsupported ctx origin exp reason suggestion =
  Premise_diagnostic.unsupported
    ~ctx
    ~origin
    ~constructor:"Premise/IfPr/MemE/binding"
    ~source_echo:(Premise_diagnostic.source_echo_exp exp)
    ~reason
    ~suggestion
    ()

let result_with_diagnostics env ~bound_vars diagnostics =
  { (Premise_result.empty_with_env ~bound_vars env) with diagnostics }

let result_with_guards env ~bound_vars guards diagnostics =
  { (Premise_result.empty_with_env ~bound_vars env) with
    eq_conditions = guards
  ; diagnostics
  }

let bind_pattern env ~bound_vars conditions diagnostics left_pattern =
  let env_after =
    Premise_state.add_introduced_bindings
      env
      left_pattern.Expr_translate.introduced_bindings
  in
  Premise_state.with_conditions env_after bound_vars conditions diagnostics

let lower_singleton_sequence_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    (left_pattern : Expr_translate.pattern_result)
    (right_result : Expr_translate.result)
    ~failure_reason
    ~failure_suggestion
  =
  match left_pattern.pattern_term, right_result.term with
  | Some left_term, Some right_term
    when (not (pattern_has_fatal left_pattern))
         && (not (result_has_fatal right_result)) ->
    let singleton_pattern = app "seq" [ left_term ] in
    let guard_bound =
      Condition_closure.conditions_bound_vars bound_vars right_result.guards
    in
    if Condition_closure.vars_subset (Condition_closure.term_vars right_term) guard_bound then
      let conditions =
        right_result.guards @ [ MatchCond (singleton_pattern, right_term) ]
        @ left_pattern.pattern_guards
      in
      Some
        (bind_pattern
           env
           ~bound_vars
           conditions
           (right_result.diagnostics @ left_pattern.pattern_diagnostics)
           left_pattern)
    else
      Some
        (result_with_diagnostics
           env
           ~bound_vars
           (right_result.diagnostics @ left_pattern.pattern_diagnostics
            @ [ unsupported
                  ctx
                  origin
                  exp
                  "binding membership computed source uses variables that are not bound before the matching condition"
                  "Bind the computed source arguments through earlier source premises before emitting the MatchCond"
              ]))
  | _ ->
    Some
      (result_with_diagnostics
         env
         ~bound_vars
         (right_result.diagnostics @ left_pattern.pattern_diagnostics
          @ [ unsupported ctx origin exp failure_reason failure_suggestion ]))

let call_result_can_bind_singleton_sequence exp typ =
  match exp.it, Premise_shape.flat_list_element_typ typ with
  | CallE _, Some _ -> true
  | _ -> false

let lower_direct_call_result_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    (left_pattern : Expr_translate.pattern_result)
    (right_result : Expr_translate.result)
  =
  match left_pattern.pattern_term, right_result.term with
  | Some left_term, Some right_term
    when (not (pattern_has_fatal left_pattern))
         && (not (result_has_fatal right_result)) ->
    let guard_bound =
      Condition_closure.conditions_bound_vars bound_vars right_result.guards
    in
    if Condition_closure.vars_subset (Condition_closure.term_vars right_term) guard_bound then
      let conditions =
        right_result.guards @ [ MatchCond (left_term, right_term) ]
        @ left_pattern.pattern_guards
      in
      Some
        (bind_pattern
           env
           ~bound_vars
           conditions
           (right_result.diagnostics @ left_pattern.pattern_diagnostics)
           left_pattern)
    else
      Some
        (result_with_diagnostics
           env
           ~bound_vars
           (right_result.diagnostics @ left_pattern.pattern_diagnostics
            @ [ unsupported
                  ctx
                  origin
                  exp
                  "binding membership call result uses variables that are not bound before the matching condition"
                  "Bind the call arguments through earlier source premises before emitting the MatchCond"
              ]))
  | _ ->
    Some
      (result_with_diagnostics
         env
         ~bound_vars
         (right_result.diagnostics @ left_pattern.pattern_diagnostics
          @ [ unsupported
                ctx
                origin
                exp
                "binding membership over a call result could not lower the left pattern or right call source"
                "Keep this premise Unsupported until both sides have source-shaped Maude terms"
            ]))

let lower_flat_sequence_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    (left_pattern : Expr_translate.pattern_result)
    right
  =
  match Premise_shape.flat_list_element_typ right.note with
  | None -> None
  | Some element_typ ->
    (match Expr_translate.carrier_sort_of_typ element_typ with
    | None -> None
    | Some element_sort when sort_name element_sort = "SpectecTerminals" -> None
    | Some _ ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      (match left_pattern.pattern_term, right_result.term with
      | Some left_term, Some right_term
        when (not (pattern_has_fatal left_pattern))
             && (not (result_has_fatal right_result)) ->
        let guard_bound =
          Condition_closure.conditions_bound_vars bound_vars right_result.guards
        in
        if Condition_closure.vars_subset (Condition_closure.term_vars right_term) guard_bound then
          let stem =
            Premise_capture.helper_local_stem
              origin
              (Premise_diagnostic.source_echo_exp exp)
          in
          let sequence_sort_name = sort_name (sort "SpectecTerminals") in
          let prefix = Var ("PREFIX" ^ stem ^ ":" ^ sequence_sort_name) in
          let suffix = Var ("SUFFIX" ^ stem ^ ":" ^ sequence_sort_name) in
          let membership_pattern =
            sequence_concat prefix (sequence_concat left_term suffix)
          in
          let conditions =
            right_result.guards
            @ [ MatchCond (membership_pattern, right_term) ]
            @ left_pattern.pattern_guards
          in
          Some
            (bind_pattern
               env
               ~bound_vars
               conditions
               (right_result.diagnostics @ left_pattern.pattern_diagnostics)
               left_pattern)
        else
          Some
            (result_with_guards
               env
               ~bound_vars
               right_result.guards
               (right_result.diagnostics @ left_pattern.pattern_diagnostics
                @ [ unsupported
                      ctx
                      origin
                      exp
                      "binding membership source sequence uses variables that are not bound before the matching condition"
                      "Bind the sequence source through earlier source premises before emitting the membership MatchCond"
                  ]))
      | _ ->
        Some
          (result_with_diagnostics
             env
             ~bound_vars
             (right_result.diagnostics @ left_pattern.pattern_diagnostics
              @ [ unsupported
                    ctx
                    origin
                    exp
                    "binding membership over a flat sequence could not lower the left pattern or right sequence source"
                    "Keep this premise Unsupported until both sides have source-shaped Maude terms"
                ]))))

let try_lower_ifpr_meme_binding ctx env ~bound_vars origin exp left right =
  let left_pattern =
    Expr_translate.lower_pattern_with_bindings ctx env origin left
  in
  if not (pattern_is_unbound bound_vars left_pattern) then
    None
  else
    match Premise_shape.flat_optional_element_typ right.note with
    | Some _ ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      lower_singleton_sequence_binding
        ctx
        env
        ~bound_vars
        origin
        exp
        left_pattern
        right_result
        ~failure_reason:
          "binding membership over an optional source could not lower the left pattern or right optional source"
        ~failure_suggestion:
          "Keep this premise Unsupported until both sides have source-shaped Maude terms"
    | None ->
      if call_result_can_bind_singleton_sequence right right.note then
        let right_result = Expr_translate.lower_sequence ctx env origin right in
        lower_direct_call_result_binding
          ctx
          env
          ~bound_vars
          origin
          exp
          left_pattern
          right_result
      else
        (match
           lower_flat_sequence_binding
             ctx
             env
             ~bound_vars
             origin
             exp
             left_pattern
             right
         with
        | Some result -> Some result
        | None ->
          Some
            (result_with_diagnostics
               env
               ~bound_vars
               (left_pattern.pattern_diagnostics
                @ [ unsupported
                      ctx
                      origin
                      exp
                      ("binding membership requires an optional singleton source or a flat sequence source whose elements have a terminal carrier; source note is `"
                       ^ Il.Print.string_of_typ right.note
                       ^ "`")
                      "Use a source-preserving membership-search helper before lowering binding membership over non-flat or nested lists"
                  ])))
