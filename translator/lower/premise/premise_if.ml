open Il.Ast
open Maude_ir
open Util.Source

let origin_for_if_conjunct = Premise_diagnostic.origin_for_if_conjunct
let with_conditions = Premise_state.with_conditions

let result_has_fatal result =
  List.exists Diagnostics.is_fatal result.Premise_result.diagnostics

let source_failure (blocker : Runtime_truth_total_equality.blocker) =
  Source_condition_certificate.failure
    ~origin:blocker.origin
    ~constructor:blocker.constructor
    ~reason:blocker.reason
    ?source_echo:blocker.source_echo
    ()

let add_source_condition_failure result blockers =
  match
    Source_condition_certificate.proof_failure
      ~positive:result.Premise_result.eq_conditions
      (List.map source_failure blockers)
  with
  | None -> result
  | Some failure ->
    { result with
      source_condition_failures =
        failure :: result.Premise_result.source_condition_failures
    }

let align_source_conditions result =
  match
    result.Premise_result.enabledness_condition_blocks,
    result.Premise_result.eq_conditions
  with
  | [], _ :: _ ->
    { result with
      enabledness_condition_blocks =
        [ Premise_result.Source_conditions result.Premise_result.eq_conditions ]
    }
  | [], [] | _ :: _, _ -> result

let lower_bool_premise ctx env ~bound_vars ~lhs_bound_vars origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  let result =
    match lowered.term with
    | Some term ->
      with_conditions ctx env bound_vars
        (lowered.guards @ [ BoolCond term ]) lowered.diagnostics
    | None ->
      { (Premise_result.empty_with_env ~bound_vars env) with
        diagnostics = lowered.diagnostics
      }
  in
  if result_has_fatal result then result else
  match
    Source_condition_certificate.prove_if
      ctx env ~bound_vars:lhs_bound_vars origin
      ~source:exp ~emitted:result.eq_conditions
  with
  | Error blockers -> add_source_condition_failure result blockers
  | Ok certificate ->
    { result with
      source_condition_certificates =
        certificate :: result.source_condition_certificates
    }

let rec lower
    names ctx env ~bound_vars ~lhs_bound_vars ~future_prems
    ~factor_head_domains origin (exp : exp) =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    let left_origin = origin_for_if_conjunct origin "and-left" left in
    let right_origin = origin_for_if_conjunct origin "and-right" right in
    let left_result, names =
      lower
        names ctx env ~bound_vars ~lhs_bound_vars ~future_prems
        ~factor_head_domains left_origin left
    in
    if result_has_fatal left_result then left_result, names else
      let right_result, names =
        lower
          names
          ctx
          left_result.env_after
          ~bound_vars:left_result.bound_vars_after
          ~lhs_bound_vars
          ~future_prems
          ~factor_head_domains
          right_origin
          right
      in
      Premise_result.append left_result right_result, names
  | CmpE (`EqOp, _, left, right) ->
    let result, names =
      Premise_eq_binding.lower_ifpr_eq
        names ctx env ~bound_vars ~lhs_bound_vars
        ~factor_head_domain:factor_head_domains origin exp left right
    in
    align_source_conditions result, names
  | MemE (left, right) ->
    let result, names =
      Premise_membership.try_lower_ifpr_meme_binding
        names ctx env ~bound_vars ~future_prems origin exp left right
    in
    (match result with
    | Some result -> align_source_conditions result, names
    | None ->
      ( align_source_conditions
          (lower_bool_premise ctx env ~bound_vars ~lhs_bound_vars origin exp)
      , names ))
  | _ ->
    ( align_source_conditions
        (lower_bool_premise ctx env ~bound_vars ~lhs_bound_vars origin exp)
    , names )
