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
    (left : Expr_translate.result)
    (right : Expr_translate.result)
  =
  left.guards @ right.guards, left.diagnostics @ right.diagnostics

let result_has_fatal (result : Expr_translate.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let app name args =
  App (name, args)

let pattern_result_has_fatal (result : Expr_translate.pattern_result) =
  List.exists Diagnostics.is_fatal result.pattern_diagnostics

let add_introduced_bindings = Premise_state.add_introduced_bindings

let lower_bool_premise ctx env ~bound_vars origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  match lowered.term with
  | Some term ->
    with_conditions env bound_vars (lowered.guards @ [ BoolCond term ]) lowered.diagnostics
  | None -> { (empty_with_env ~bound_vars env) with diagnostics = lowered.diagnostics }

let typecheck_for_sort = Premise_shape.typecheck_for_sort
let try_match_condition
    ~bound
    (pattern_result : Expr_translate.pattern_result)
    (subject_result : Expr_translate.result)
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
    (left_result : Expr_translate.result).term,
    (right_result : Expr_translate.result).term
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
  | VarE id when Expr_translate.find_var env id.it = None ->
    category_named_var ctx id
  | SubE ({ it = VarE id; _ }, { it = VarT (typ_id, []); _ }, _)
    when id.it = typ_id.it
         && (match Expr_translate.find_var env id.it with
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
          BoolCond (typecheck_for_sort value_sort value_term witness)
        in
        with_conditions
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

let try_category_membership_eq ctx env ~bound_vars origin left right () =
  lower_category_membership_eq_premise ctx env ~bound_vars origin left right

let try_inverse_binding_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_inverse_binding.lower ctx env ~bound_vars origin exp left right

let try_fixed_inverse_concat_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_fixed_inverse_concat.lower
    ctx env ~bound_vars origin exp left right

let try_inverse_concatn_chunks_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_inverse_concatn_chunks.lower
    ctx env ~bound_vars origin exp left right

let try_declared_inverse_fallback_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_declared_inverse_fallback.lower
    ctx env ~bound_vars origin exp left right

let try_numeric_inverse_binding_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_numeric_inverse.lower ctx env ~bound_vars origin exp left right

let try_unary_projection_binding_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_value_binding.lower_unary_projection
    ctx env ~bound_vars origin exp left right

let try_direct_var_binding_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_value_binding.lower_direct_var
    ctx env ~bound_vars origin exp left right

let try_optional_map_inverse_eq ctx env ~bound_vars origin exp left right () =
  Premise_eq_optional_map_inverse.lower ctx env ~bound_vars origin exp left right

let try_record_eq_match env ~bound_vars left right left_value right_value left_pattern right_pattern () =
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
    Some (with_conditions env_after bound_vars conditions diagnostics)
  | None -> None

let try_pattern_eq_match env ~bound_vars pattern_result value_result () =
  match try_match_condition ~bound:bound_vars pattern_result value_result with
  | Some (conditions, diagnostics) ->
    let env_after =
      add_introduced_bindings env pattern_result.introduced_bindings
    in
    Some (with_conditions env_after bound_vars conditions diagnostics)
  | None -> None

let try_plain_eq ctx env ~bound_vars left_value right_value () =
  match try_eq_condition left_value right_value with
  | Some (conditions, diagnostics) ->
    let conditions =
      invert_unbound_unary_projection_conditions ctx bound_vars conditions
    in
    Some (with_conditions env bound_vars conditions diagnostics)
  | None -> None

let lower_ifpr_eq ctx env ~bound_vars origin (exp : exp) (left : exp) (right : exp) =
  match
    first_success
      [ try_category_membership_eq ctx env ~bound_vars origin left right
      ; try_category_membership_eq ctx env ~bound_vars origin right left
      ; try_direct_var_binding_eq ctx env ~bound_vars origin exp left right
      ; try_direct_var_binding_eq ctx env ~bound_vars origin exp right left
      ; try_unary_projection_binding_eq ctx env ~bound_vars origin exp left right
      ; try_unary_projection_binding_eq ctx env ~bound_vars origin exp right left
      ; try_inverse_binding_eq ctx env ~bound_vars origin exp left right
      ; try_inverse_binding_eq ctx env ~bound_vars origin exp right left
      ; try_fixed_inverse_concat_eq ctx env ~bound_vars origin exp left right
      ; try_fixed_inverse_concat_eq ctx env ~bound_vars origin exp right left
      ; try_inverse_concatn_chunks_eq ctx env ~bound_vars origin exp left right
      ; try_inverse_concatn_chunks_eq ctx env ~bound_vars origin exp right left
      ; try_declared_inverse_fallback_eq ctx env ~bound_vars origin exp left right
      ; try_declared_inverse_fallback_eq ctx env ~bound_vars origin exp right left
      ; try_optional_map_inverse_eq ctx env ~bound_vars origin exp left right
      ; try_optional_map_inverse_eq ctx env ~bound_vars origin exp right left
      ; try_numeric_inverse_binding_eq ctx env ~bound_vars origin exp left right
      ; try_numeric_inverse_binding_eq ctx env ~bound_vars origin exp right left
      ]
  with
  | Some result -> result
  | None ->
    let left_value = Expr_translate.lower_value ctx env origin left in
    let right_value = Expr_translate.lower_value ctx env origin right in
    let left_pattern = Expr_translate.lower_pattern_with_bindings ctx env origin left in
    let right_pattern = Expr_translate.lower_pattern_with_bindings ctx env origin right in
    match
      first_success
        [ try_record_eq_match
            env
            ~bound_vars
            left
            right
            left_value
            right_value
            left_pattern
            right_pattern
        ; try_pattern_eq_match env ~bound_vars left_pattern right_value
        ; try_pattern_eq_match env ~bound_vars right_pattern left_value
        ; try_plain_eq ctx env ~bound_vars left_value right_value
        ]
    with
    | Some result -> result
    | None -> lower_bool_premise ctx env ~bound_vars origin exp
