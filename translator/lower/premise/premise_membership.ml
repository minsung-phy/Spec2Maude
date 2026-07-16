open Maude_ir
open Util.Source

module Request = Helper_request

(* Binding-only lowering for IfPr(MemE(left, right)).
   Ordinary membership checks stay in Premise_translate so the MemE
   constructor remains visible at the dispatcher boundary. *)

let pattern_has_fatal (result : Expr_result.pattern_result) =
  List.exists Diagnostics.is_fatal result.pattern_diagnostics

let result_has_fatal (result : Expr_result.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let pattern_is_unbound bound_vars (result : Expr_result.pattern_result) =
  match result.pattern_term with
  | None -> false
  | Some term ->
    not (Condition_closure.vars_subset (Condition_closure.term_vars term) bound_vars)

let unsupported ?deferral ctx origin exp reason suggestion =
  match deferral with
  | None ->
    Premise_diagnostic.unsupported
      ~ctx
      ~origin
      ~constructor:"Premise/IfPr/MemE/binding"
      ~source_echo:(Premise_diagnostic.source_echo_exp exp)
      ~reason
      ~suggestion
      ()
  | Some deferral ->
    Diagnostics.make
      ~category:Diagnostics.Unsupported
      ~origin
      ~constructor:"Premise/IfPr/MemE/binding"
      ~enclosing:(Context.enclosing_path ctx)
      ~profile:(Context.profile_name ctx)
      ~source_echo:(Premise_diagnostic.source_echo_exp exp)
      ~reason
      ~suggestion
      ~deferral
      ()

let result_with_diagnostics env ~bound_vars diagnostics =
  { (Premise_result.empty_with_env ~bound_vars env) with diagnostics }

let result_with_guards
    ?(blocked_witness_source_ids = []) env ~bound_vars guards diagnostics =
  { (Premise_result.empty_with_env ~bound_vars env) with
    eq_conditions = guards
  ; blocked_witness_source_ids
  ; diagnostics
  }

let source_dependency_ids env bound source term =
  let missing_vars =
    Condition_closure.term_vars term
    |> List.filter (fun var -> not (List.mem var bound))
  in
  Source_free_vars.exp_and_note_ids source
  |> List.filter (fun source_id ->
    match Expr_env.find env source_id with
    | Some binding ->
      Condition_closure.term_vars binding.Expr_env.term
      |> List.exists (fun var -> List.mem var missing_vars)
    | None -> false)
  |> List.sort_uniq String.compare

let later_premise_source_ids future_prems =
  future_prems
  |> List.concat_map Source_free_vars.prem_and_note_ids
  |> List.sort_uniq String.compare

let unbound_source_result
    ctx env ~bound_vars ~future_prems origin exp source term bound guards
    diagnostics reason suggestion =
  let dependencies = source_dependency_ids env bound source term in
  let later_ids = later_premise_source_ids future_prems in
  let retryable =
    dependencies <> []
    && List.for_all (fun id -> List.mem id later_ids) dependencies
  in
  let reason =
    if retryable then
      reason
      ^ "; later source premise dependency id(s): "
      ^ String.concat ", " dependencies
    else
      reason
  in
  let deferral, blocked_witness_source_ids =
    if retryable then
      Some Diagnostics.Binding_membership_admissibility, dependencies
    else
      None, []
  in
  (* Deferral is only a scheduling hint.  A later candidate must complete and
     extend bound_vars before this premise can commit; fixed-point failure keeps
     the original Unsupported diagnostic and commits no helper state. *)
  result_with_guards
    ~blocked_witness_source_ids
    env
    ~bound_vars
    guards
    (diagnostics
     @ [ unsupported ?deferral ctx origin exp reason suggestion ])

let bind_pattern ctx env ~bound_vars conditions diagnostics left_pattern =
  let env_after =
    Premise_state.add_introduced_bindings
      env
      left_pattern.Expr_result.introduced_bindings
  in
  Premise_state.with_conditions ctx env_after bound_vars conditions diagnostics

let lower_optional_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    source
    ~future_prems
    (left_pattern : Expr_result.pattern_result)
    (right_result : Expr_result.result)
    ~failure_reason
    ~failure_suggestion
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
        (bind_pattern ctx
           env
           ~bound_vars
           conditions
           (right_result.diagnostics @ left_pattern.pattern_diagnostics)
           left_pattern)
    else
      Some
        (unbound_source_result
           ctx
           env
           ~bound_vars
           ~future_prems
           origin
           exp
           source
           right_term
           guard_bound
           right_result.guards
           (right_result.diagnostics @ left_pattern.pattern_diagnostics)
           "binding membership computed source uses variables that are not bound before the matching condition"
           "Bind the computed source arguments through earlier source premises before emitting the MatchCond")
  | _ ->
    Some
      (result_with_diagnostics
         env
         ~bound_vars
         (right_result.diagnostics @ left_pattern.pattern_diagnostics
          @ [ unsupported ctx origin exp failure_reason failure_suggestion ]))

let lower_flat_sequence_binding
    ctx
    env
    ~bound_vars
    origin
    exp
    ~future_prems
    (left_pattern : Expr_result.pattern_result)
    right
  =
  match Premise_shape.flat_list_element_typ right.note with
  | None -> None
  | Some element_typ ->
    (match Expr_translate.carrier_sort_of_typ element_typ with
    | None -> None
    | Some element_sort when sort_name element_sort = "SpectecTerminals" -> None
    | Some element_sort ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      (match left_pattern.pattern_term, right_result.term with
      | Some left_term, Some right_term
        when (not (pattern_has_fatal left_pattern))
             && (not (result_has_fatal right_result)) ->
        let guard_bound =
          Condition_closure.conditions_bound_vars bound_vars right_result.guards
        in
        if Condition_closure.vars_subset (Condition_closure.term_vars right_term) guard_bound then
          let head_var, names =
            Local_name.fresh_qualified_name
              Local_name.empty Local_name.Head (sort_ref element_sort)
          in
          let tail_var, names =
            Local_name.fresh_qualified_name
              names Local_name.Tail (sort_ref (sort "SpectecTerminals"))
          in
          let witness_var, _ =
            Local_name.fresh_qualified_name
              names Local_name.Witness (sort_ref element_sort)
          in
          let request =
            { Membership_witness_helper.source =
                Premise_diagnostic.source_echo_exp exp
            ; element_sort
            ; head_var
            ; tail_var
            ; witness_var
            }
          in
          let helper_request =
            { Request.kind = Membership_witness request
            ; reason =
                "source binding MemE over a finite flat sequence"
            ; origin
            }
          in
          let helper_name =
            Helper.request (Context.helpers ctx) helper_request
          in
          let pattern_certificate =
            Membership_witness_helper.materialize ~name:helper_name origin request
            |> Condition_pattern_certificate.generated
          in
          let env_after =
            Premise_state.add_introduced_bindings
              env left_pattern.introduced_bindings
          in
          let rewrite =
            RewriteCond
              ( Membership_witness_helper.call helper_name right_term
              , Membership_witness_helper.result helper_name left_term )
          in
          let rule_conditions =
            rewrite
            :: List.map (fun condition -> EqCondition condition)
                 left_pattern.pattern_guards
          in
          let bound_after_guards =
            Condition_closure.conditions_bound_vars
              ~constructor_op:
                (Condition_closure.source_constructor_certificate ctx)
              bound_vars right_result.guards
          in
          let bound_vars_after =
            Condition_closure.rule_conditions_bound_vars
              ~constructor_op:
                (Condition_pattern_certificate.union
                   (Condition_closure.source_constructor_certificate ctx)
                   pattern_certificate)
              bound_after_guards rule_conditions
          in
          Some
            { (Premise_result.empty_with_env
                 ~bound_vars:bound_vars_after env_after) with
              eq_conditions = right_result.guards
            ; rule_conditions
            ; pattern_certificate
            ; diagnostics =
                right_result.diagnostics
                @ left_pattern.pattern_diagnostics
            }
        else
          Some
            (unbound_source_result
               ctx
               env
               ~bound_vars
               ~future_prems
               origin
               exp
               right
               right_term
               guard_bound
               right_result.guards
               (right_result.diagnostics @ left_pattern.pattern_diagnostics)
               "binding membership source sequence uses variables that are not bound before the matching condition"
               "Bind the sequence source through earlier source premises before emitting the membership MatchCond")
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

let try_lower_ifpr_meme_binding
    names ctx env ~bound_vars ~future_prems origin exp left right =
  let incoming_names = names in
  let left_pattern, names =
    Expr_translate.lower_pattern_with_bindings_named names ctx env origin left
  in
  if not (pattern_is_unbound bound_vars left_pattern) then
    None, incoming_names
  else
    let result = match Premise_shape.flat_optional_element_typ right.note with
    | Some _ ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      lower_optional_binding
        ctx
        env
        ~bound_vars
        origin
        exp
        right
        ~future_prems
        left_pattern
        right_result
        ~failure_reason:
          "binding membership over an optional source could not lower the left pattern or right optional source"
        ~failure_suggestion:
          "Keep this premise Unsupported until both sides have source-shaped Maude terms"
    | None ->
      (match
         lower_flat_sequence_binding
           ctx
           env
           ~bound_vars
           origin
           exp
           ~future_prems
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
    in
    match result with
    | Some _ -> result, names
    | None -> None, incoming_names
