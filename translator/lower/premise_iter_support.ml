open Maude_ir

include Premise_result

type lower_body =
  Expr_translate.env ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  result

let unsupported = Premise_diagnostic.unsupported
let source_echo_prem = Premise_diagnostic.source_echo_prem
let source_echo_exp = Premise_diagnostic.source_echo_exp
let unsupported_prem = Premise_diagnostic.unsupported_prem

let vars_subset = Condition_closure.vars_subset
let conditions_bound_vars = Condition_closure.conditions_bound_vars
let with_conditions = Premise_state.with_conditions
let take_match_binding = Premise_state.take_match_binding

let diagnostics_have_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let flat_optional_element_typ = Premise_shape.flat_optional_element_typ
let flat_list_element_typ = Premise_shape.flat_list_element_typ
let zip_source_descriptor = Premise_shape.zip_source_descriptor

let app name args =
  App (name, args)
