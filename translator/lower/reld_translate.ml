open Util.Source

open Reld_common

type output = Reld_common.output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

let translate ctx origin id params mixop result_typ rules =
  let relation_shape = Relation_shape.of_reld params mixop result_typ in
  let relation_kind = relation_shape.Relation_shape.marker in
  let relation_kind_text = relation_shape.Relation_shape.marker_text in
  if params <> [] then
    one_diagnostic
      (unsupported
         ~ctx
         ~origin
         ~constructor:"RelD/params"
         ~reason:
           ("relation `"
            ^ id.it
            ^ "` has source parameters `"
            ^ Il.Print.string_of_params params
            ^ "`, but parameterized relation lowering is not implemented yet")
         ~suggestion:
           "Preserve this RelD as Unsupported until RulePr argument instantiation and relation specialization/tag lowering are designed source-completely"
         ())
  else
  match relation_shape.Relation_shape.decision with
  | Relation_shape.Static_validation _ ->
    (match
       Analysis.Function_graph.relation_runtime_demand_reason
         (Context.function_graph ctx)
         id.it
     with
    | Some runtime_reason ->
      Reld_runtime_predicate.translate
        ctx
        origin
        id
        relation_kind
        mixop
        runtime_reason
        relation_shape.Relation_shape.components
        rules
    | None ->
      one_diagnostic
        (skipped
           ~ctx
           ~origin
           ~constructor:"RelD/static-validation"
           ~reason:
             ("static validation predicate relation is discharged by the official validator in Runtime_after_external_validation; structural relation classification is "
              ^ relation_kind_text)
           ~suggestion:
             "Keep the source relation in diagnostics/metadata; emit no runtime Maude statements for this validation-only RelD"
           ()))
  | Relation_shape.Runtime_predicate runtime_reason ->
    Reld_runtime_predicate.translate
      ctx
      origin
      id
      relation_kind
      mixop
      runtime_reason
      relation_shape.Relation_shape.components
      rules
  | Relation_shape.Deterministic_candidate shape ->
    Reld_deterministic.translate ctx origin id relation_kind mixop shape rules
  | Relation_shape.Execution shape ->
    if Reld_equational_view.relation_has_maude_equational_view ctx id then
      Reld_equational_view.translate ctx origin id shape rules
    else
      Reld_execution.translate ctx origin id relation_kind mixop shape rules
  | Relation_shape.Unknown reason ->
    one_diagnostic
      (unsupported
         ~ctx
         ~origin
         ~constructor:"RelD"
         ~reason:
           ("RelD marker is not classified as validation, deterministic, or execution; structural relation classification is "
            ^ relation_kind_text
            ^ "; "
            ^ reason)
         ~suggestion:
           "Classify this relation structurally before deciding whether to skip or lower it"
         ())
