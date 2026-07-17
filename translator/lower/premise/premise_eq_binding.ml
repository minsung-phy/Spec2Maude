open Il.Ast
open Maude_ir
open Util.Source

include Premise_result

(* Lowering for IfPr(CmpE(EqOp, left, right)).

   The public dispatcher in Premise_translate keeps the Il.Ast constructor
   match visible; this module owns only the equality-specific binding,
   inverse, pattern-match, and plain EqCond attempts. *)

let vars_subset = Condition_closure.vars_subset
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let with_conditions = Premise_state.with_conditions

let result_metadata
    (left : Expr_result.result)
    (right : Expr_result.result)
  =
  left.guards @ right.guards, left.diagnostics @ right.diagnostics

let result_has_fatal (result : Expr_result.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let app name args =
  App (name, args)

let pattern_result_has_fatal (result : Expr_result.pattern_result) =
  List.exists Diagnostics.is_fatal result.pattern_diagnostics

let add_introduced_bindings = Premise_state.add_introduced_bindings

let lower_bool_premise ctx env ~bound_vars origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  match lowered.term with
  | Some term ->
    with_conditions ctx env bound_vars
      (lowered.guards @ [ BoolCond term ]) lowered.diagnostics
  | None -> { (empty_with_env ~bound_vars env) with diagnostics = lowered.diagnostics }

let try_match_condition
    ~bound
    (pattern_result : Expr_result.pattern_result)
    (subject_result : Expr_result.result)
  =
  match pattern_result.pattern_term, subject_result.term with
  | Some pattern, Some subject ->
    let guard_bound =
      conditions_bound_vars bound subject_result.guards
    in
    if
      (not (pattern_result_has_fatal pattern_result))
      && (not (result_has_fatal subject_result))
      && vars_subset (Condition_closure.term_vars subject) guard_bound
    then
      let conditions =
        subject_result.guards @ [ MatchCond (pattern, subject) ] @ pattern_result.pattern_guards
      in
      Some
        ( conditions
        , subject_result.diagnostics @ pattern_result.pattern_diagnostics )
    else
      None
  | _ -> None

let try_eq_condition left_result right_result =
  match
    (left_result : Expr_result.result).term,
    (right_result : Expr_result.result).term
  with
  | Some left, Some right ->
    if result_has_fatal left_result || result_has_fatal right_result then
      None
    else
      let guards, diagnostics = result_metadata left_result right_result in
      Some (guards @ [ EqCond (left, right) ], diagnostics)
  | _ -> None

let invert_unbound_unary_projection_condition ctx bound condition =
  let inverse projection_op scrutinee payload =
    match scrutinee with
    | Var name when not (List.mem name bound) ->
      (match
         Constructor_registry.lookup_unary_projection
           (Context.constructors ctx)
           ~projection_op
       with
      | Constructor_registry.Projection_found entry ->
        Some
          (MatchCond
             ( Var name
             , app entry.Constructor_registry.constructor_op [ payload ] ))
      | Constructor_registry.Projection_missing
      | Constructor_registry.Projection_ambiguous _ -> None)
    | _ -> None
  in
  match condition with
  | EqCond (App (projection_op, [ scrutinee ]), payload) ->
    (match inverse projection_op scrutinee payload with
    | Some condition -> condition
    | None -> condition)
  | EqCond (payload, App (projection_op, [ scrutinee ])) ->
    (match inverse projection_op scrutinee payload with
    | Some condition -> condition
    | None -> condition)
  | EqCond _ -> condition
  | MatchCond _ | MembershipCond _ | BoolCond _ -> condition

let invert_unbound_unary_projection_conditions ctx bound conditions =
  let step (bound, conditions) condition =
    let condition =
      invert_unbound_unary_projection_condition ctx bound condition
    in
    let bound = conditions_bound_vars bound [ condition ] in
    bound, conditions @ [ condition ]
  in
  conditions |> List.fold_left step (bound, []) |> snd

let try_record_match_condition ~bound pattern_result subject_result =
  try_match_condition ~bound pattern_result subject_result
let category_named_var ctx id =
  Analysis.Source_index.find_by_id (Context.source_index ctx) id.it
  |> List.find_map (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | TypD (typ_id, [], _) when typ_id.it = id.it ->
        Some (Const (Naming.category_witness id))
      | _ -> None)

let binding_is_bound = Premise_state.binding_is_bound

let source_category_witness ctx env ~bound_vars exp =
  match exp.it with
  | VarE id when Expr_env.find env id.it = None ->
    category_named_var ctx id
  | SubE ({ it = VarE id; _ }, { it = VarT (typ_id, []); _ }, _)
    when id.it = typ_id.it
         && (match Expr_env.find env id.it with
             | None -> true
             | Some binding -> not (binding_is_bound bound_vars binding)) ->
    category_named_var ctx id
  | _ -> None

let lower_category_membership_eq_premise ctx env ~bound_vars origin value_exp category_exp =
  match source_category_witness ctx env ~bound_vars category_exp with
  | None -> None
  | Some witness ->
    let value_result = Expr_translate.lower_value ctx env origin value_exp in
    let sort_opt = Expr_translate.carrier_sort_of_typ value_exp.note in
    Some
      (match value_result.term, sort_opt with
      | Some value_term, Some value_sort ->
        let condition =
          BoolCond (Typecheck_term.typecheck_for_sort value_sort value_term witness)
        in
        with_conditions ctx
          env
          bound_vars
          (value_result.guards @ [ condition ])
          value_result.diagnostics
      | _ ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = value_result.guards
        ; diagnostics = value_result.diagnostics
        })

let first_success attempts =
  attempts |> List.find_map (fun attempt -> attempt ())

let first_success_tagged attempts =
  attempts
  |> List.find_map (fun (tag, attempt) ->
    Option.map (fun result -> tag, result) (attempt ()))

let exact_binding_source (exp : exp) =
  match exp.it with
  | VarE _ -> Some exp
  | IterE
      ({ it = VarE body_id; _ },
       ((Opt | List), [ generator_id, source_exp ]))
    when body_id.it = generator_id.it -> Some source_exp
  | _ -> None

let source_binding_is_unbound names env ~bound_vars exp =
  match exact_binding_source exp with
  | None -> false
  | Some source ->
    Option.is_some
      (Premise_state.unbound_var_binding names env ~bound_vars source)

let has_match_condition result =
  result.eq_conditions
  |> List.exists (function
    | MatchCond _ -> true
    | EqCond _ | BoolCond _ | MembershipCond _ -> false)

let try_category_membership_eq ctx env ~bound_vars origin left right () =
  lower_category_membership_eq_premise ctx env ~bound_vars origin left right

let try_inverse_binding_eq names ctx env ~bound_vars origin exp left right () =
  Premise_eq_inverse_binding.lower
    names ctx env ~bound_vars origin exp left right

let try_fixed_inverse_concat_eq names ctx env ~bound_vars origin exp left right () =
  Premise_eq_fixed_inverse_concat.lower
    names ctx env ~bound_vars origin exp left right

let try_inverse_concatn_chunks_eq names ctx env ~bound_vars origin exp left right () =
  Premise_eq_inverse_concatn_chunks.lower
    names ctx env ~bound_vars origin exp left right

let try_declared_inverse_fallback_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_declared_inverse_fallback.lower
    ctx env ~bound_vars origin exp left right

let try_numeric_inverse_binding_eq names ctx env ~bound_vars origin exp left right () =
  Premise_eq_numeric_inverse.lower
    names ctx env ~bound_vars origin exp left right

let try_unary_projection_binding_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_value_binding.lower_unary_projection
    ctx env ~bound_vars origin exp left right

let try_direct_var_binding_eq names ctx env ~bound_vars origin exp left right () =
  Premise_eq_value_binding.lower_direct_var
    names ctx env ~bound_vars origin exp left right

let try_optional_map_inverse_eq names ctx env ~bound_vars origin exp left right () =
  Premise_eq_optional_map_inverse.lower
    names ctx env ~bound_vars origin exp left right

let try_record_eq_match
    ctx env ~bound_vars left right left_value right_value left_pattern right_pattern () =
  let record_match =
    match left.it, right.it with
    | _, StrE _ ->
      try_record_match_condition ~bound:bound_vars right_pattern left_value
    | StrE _, _ ->
      try_record_match_condition ~bound:bound_vars left_pattern right_value
    | _ -> None
  in
  match record_match with
  | Some (conditions, diagnostics) ->
    let env_after =
      match left.it, right.it with
      | _, StrE _ -> add_introduced_bindings env right_pattern.introduced_bindings
      | StrE _, _ -> add_introduced_bindings env left_pattern.introduced_bindings
      | _ -> env
    in
    Some (with_conditions ctx env_after bound_vars conditions diagnostics)
  | None -> None

let try_pattern_eq_match ctx env ~bound_vars pattern_result value_result () =
  let introduces_unbound =
    match pattern_result.Expr_result.pattern_term with
    | None -> false
    | Some pattern ->
      let pattern_bound =
        Condition_closure.term_vars pattern @ bound_vars
        |> List.sort_uniq String.compare
      in
      let guard_bound =
        conditions_bound_vars
          ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
          pattern_bound pattern_result.pattern_guards
      in
      not (vars_subset (Condition_closure.term_vars pattern) bound_vars)
      || not (vars_subset guard_bound pattern_bound)
  in
  if not introduces_unbound then None else
    match try_match_condition ~bound:bound_vars pattern_result value_result with
    | Some (conditions, diagnostics) ->
      let env_after =
        add_introduced_bindings env pattern_result.introduced_bindings
      in
      Some (with_conditions ctx env_after bound_vars conditions diagnostics)
    | None -> None

let try_plain_eq ctx env ~bound_vars left_value right_value () =
  match try_eq_condition left_value right_value with
  | Some (conditions, diagnostics) ->
    let conditions =
      invert_unbound_unary_projection_conditions ctx bound_vars conditions
    in
    Some (with_conditions ctx env bound_vars conditions diagnostics)
  | None -> None

let attach_total_equality_certificate
    ctx env ~lhs_bound_vars origin exp _left _right
    (result : Premise_result.result) =
  if List.exists Diagnostics.is_fatal result.diagnostics then result else
  match
    Source_condition_certificate.prove_if
      ctx env ~bound_vars:lhs_bound_vars origin
      ~source:exp ~emitted:result.eq_conditions
  with
  | Error blockers ->
    let blockers =
      blockers
      |> List.map (fun (blocker : Runtime_truth_totality.blocker) ->
        Source_condition_certificate.failure
          ~origin:blocker.origin
          ~constructor:blocker.constructor
          ~reason:blocker.reason
          ?source_echo:blocker.source_echo
          ())
    in
    (match
       Source_condition_certificate.proof_failure
         ~positive:result.eq_conditions blockers
     with
    | None -> result
    | Some failure ->
      { result with
        source_condition_failures =
          failure :: result.source_condition_failures
      })
  | Ok certificate ->
    { result with
      source_condition_certificates =
        certificate :: result.source_condition_certificates
    }

let fresh_match_prefix ctx ~bound_vars conditions =
  let rec loop prefix = function
    | [] -> None
    | MatchCond (pattern, subject) :: _ ->
      let bound =
        conditions_bound_vars
          ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
          bound_vars (List.rev prefix)
      in
      if vars_subset (Condition_closure.term_vars subject) bound
         && not (vars_subset (Condition_closure.term_vars pattern) bound)
      then Some (List.rev prefix)
      else None
    | condition :: rest -> loop (condition :: prefix) rest
  in
  loop [] conditions

let attach_binding_certificate
    ctx env ~lhs_bound_vars origin value_exp
    (result : Premise_result.result) =
  if List.exists Diagnostics.is_fatal result.diagnostics then result else
  match fresh_match_prefix ctx ~bound_vars:lhs_bound_vars result.eq_conditions with
  | None -> result
  | Some emitted ->
    (match
       Source_condition_certificate.prove_binding
         ctx env ~bound_vars:lhs_bound_vars origin
         ~source:value_exp ~emitted
     with
    | Ok None -> result
    | Ok (Some certificate) ->
      { result with
        source_condition_certificates =
          certificate :: result.source_condition_certificates
      }
    | Error blockers ->
      let blockers =
        blockers
        |> List.map (fun (blocker : Runtime_truth_totality.blocker) ->
          Source_condition_certificate.failure
            ~origin:blocker.origin
            ~constructor:blocker.constructor
            ~reason:blocker.reason
            ?source_echo:blocker.source_echo
            ())
      in
      (match
         Source_condition_certificate.proof_failure
           ~positive:emitted blockers
       with
      | None -> result
      | Some failure ->
        { result with
          source_condition_failures =
            failure :: result.source_condition_failures
        }))

let binding_value_exp names env ~bound_vars left right =
  match
    source_binding_is_unbound names env ~bound_vars left,
    source_binding_is_unbound names env ~bound_vars right
  with
  | true, false -> Some right
  | false, true -> Some left
  | false, false | true, true -> None

let lower_ifpr_eq
    names ctx env ~bound_vars ~lhs_bound_vars ~factor_head_domain origin
    (exp : exp) (left : exp) (right : exp) =
  let factored, result, names =
  match
    first_success_tagged
      [ false, try_category_membership_eq ctx env ~bound_vars origin left right
      ; false, try_category_membership_eq ctx env ~bound_vars origin right left
      ; true, try_direct_var_binding_eq names ctx env ~bound_vars origin exp left right
      ; true, try_direct_var_binding_eq names ctx env ~bound_vars origin exp right left
      ; false, try_unary_projection_binding_eq ctx env ~bound_vars origin exp left right
      ; false, try_unary_projection_binding_eq ctx env ~bound_vars origin exp right left
      ; false, try_inverse_binding_eq names ctx env ~bound_vars origin exp left right
      ; false, try_inverse_binding_eq names ctx env ~bound_vars origin exp right left
      ; false, try_fixed_inverse_concat_eq names ctx env ~bound_vars origin exp left right
      ; false, try_fixed_inverse_concat_eq names ctx env ~bound_vars origin exp right left
      ; false, try_inverse_concatn_chunks_eq names ctx env ~bound_vars origin exp left right
      ; false, try_inverse_concatn_chunks_eq names ctx env ~bound_vars origin exp right left
      ; false, try_declared_inverse_fallback_eq ctx env ~bound_vars origin exp left right
      ; false, try_declared_inverse_fallback_eq ctx env ~bound_vars origin exp right left
      ; false, try_optional_map_inverse_eq names ctx env ~bound_vars origin exp left right
      ; false, try_optional_map_inverse_eq names ctx env ~bound_vars origin exp right left
      ; false, try_numeric_inverse_binding_eq names ctx env ~bound_vars origin exp left right
      ; false, try_numeric_inverse_binding_eq names ctx env ~bound_vars origin exp right left
      ]
  with
  | Some (factored, result) -> factored, result, names
  | None ->
    let left_value = Expr_translate.lower_value ctx env origin left in
    let right_value = Expr_translate.lower_value ctx env origin right in
    let left_pattern, names =
      Expr_translate.lower_pattern_with_bindings_named names ctx env origin left
    in
    let right_pattern, names =
      Expr_translate.lower_pattern_with_bindings_named names ctx env origin right
    in
    match
      first_success
        [ try_record_eq_match ctx
            env
            ~bound_vars
            left
            right
            left_value
            right_value
            left_pattern
            right_pattern
        ; try_pattern_eq_match ctx env ~bound_vars left_pattern right_value
        ; try_pattern_eq_match ctx env ~bound_vars right_pattern left_value
        ; try_plain_eq ctx env ~bound_vars left_value right_value
        ]
    with
    | Some result -> false, result, names
    | None -> false, lower_bool_premise ctx env ~bound_vars origin exp, names
  in
  let factored =
    factored
    || (has_match_condition result
        && (source_binding_is_unbound names env ~bound_vars left
            || source_binding_is_unbound names env ~bound_vars right))
  in
  if factor_head_domain && factored then
    ( { result with
        enabledness_condition_blocks =
          [ Head_domain_conditions result.eq_conditions ]
      }
    , names )
  else
    match binding_value_exp names env ~bound_vars left right with
    | Some value_exp when has_match_condition result ->
      attach_binding_certificate
        ctx env ~lhs_bound_vars origin value_exp result, names
    | Some _ | None ->
      attach_total_equality_certificate
        ctx env ~lhs_bound_vars origin exp left right result, names
