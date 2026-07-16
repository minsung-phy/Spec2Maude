open Il.Ast
open Util.Source

let unsupported_prem = Premise_diagnostic.unsupported_prem
let skipped_prem = Premise_diagnostic.skipped_prem

let lower
    names
    ctx
    env
    ~allow_runtime_search
    ~discharge_static_validation
    ~bound_vars
    ~blocked_witness_source_ids
    ~future_prems
    ~escape_source_ids
    ~factor_head_domains
    origin
    prem
    rel_id
    mixop =
  match
    Analysis.Function_graph.find_relation
      (Context.function_graph ctx) rel_id.it
  with
  | None ->
    ( unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/unresolved" prem
        ("relation premise references `" ^ rel_id.it
       ^ "`, but no matching RelD was found in the source index")
    , names )
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    if local_kind <> relation_shape.Relation_shape.marker then
      ( unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/mixop" prem
          ("source relation marker mismatch: referenced relation is `"
         ^ relation_shape.Relation_shape.marker_text
         ^ "`, but this RulePr local mixop is `"
         ^ Analysis.Relation_graph.string_of_relation_kind local_kind
         ^ "`")
      , names )
    else if not (Analysis.Relation_graph.eq_mixop relation.mixop mixop) then
      ( unsupported_prem ctx env ~bound_vars origin
          "Premise/RulePr/mixop-skeleton" prem
          ("source relation mixop skeleton mismatch: referenced RelD `"
         ^ rel_id.it
         ^ "` uses `"
         ^ Analysis.Relation_graph.mixop_shape_text relation.mixop
         ^ "`, but this RulePr uses `"
         ^ Analysis.Relation_graph.mixop_shape_text mixop
         ^ "`")
      , names )
    else
      match relation_shape.Relation_shape.decision with
      | Relation_shape.Static_validation _ ->
        (match
           Context.runtime_relation_use_reason ctx rel_id.it
           |> Option.fold
                ~none:
                  (Analysis.Function_graph.relation_runtime_demand_reason
                     (Context.function_graph ctx) rel_id.it)
                ~some:(fun reason -> Some reason)
         with
        | Some runtime_reason ->
          (match prem.it with
          | RulePr (_, _, _, exp) ->
            ( Premise_rule_runtime_predicate.lower
                ctx
                env
                ~allow_runtime_search
                ~bound_vars
                ~blocked_witness_source_ids
                ~escape_source_ids
                ~future_prems
                origin
                prem
                rel_id
                exp
                relation_shape
            , names )
          | _ ->
            ( unsupported_prem ctx env ~bound_vars origin
                "Premise/RulePr/runtime-demanded-predicate" prem
                ("relation is static by signature but runtime-demanded by the relation call graph: "
                 ^ runtime_reason)
            , names ))
        | None when discharge_static_validation ->
          ( skipped_prem ctx env ~bound_vars origin
              "Premise/RulePr/static-validation" prem
              ("static validation relation premise is discharged because the runtime starts from an initial configuration checked by the official validator; structural relation classification is "
               ^ relation_shape.Relation_shape.marker_text)
              "Keep the source premise in diagnostics/metadata; emit no runtime Maude condition for this validation-only premise"
          , names )
        | None ->
          (match prem.it with
          | RulePr (_, _, _, exp) ->
            ( Premise_rule_runtime_predicate.lower
                ctx env ~allow_runtime_search ~bound_vars
                ~blocked_witness_source_ids ~escape_source_ids ~future_prems
                origin prem rel_id exp relation_shape
            , names )
          | _ ->
            ( unsupported_prem ctx env ~bound_vars origin
                "Premise/RulePr/runtime-demanded-predicate" prem
                "active runtime truth materialization expected a RulePr AST node"
            , names )))
      | Relation_shape.Runtime_predicate _ ->
        (match prem.it with
        | RulePr (_, _, _, exp) ->
          ( Premise_rule_runtime_predicate.lower
              ctx
              env
              ~allow_runtime_search
              ~bound_vars
              ~blocked_witness_source_ids
              ~escape_source_ids
              ~future_prems
              origin
              prem
              rel_id
              exp
              relation_shape
          , names )
        | _ ->
          ( unsupported_prem ctx env ~bound_vars origin
              "Premise/RulePr/runtime-predicate" prem
              "runtime predicate premise lowering expected a RulePr AST node"
          , names ))
      | Relation_shape.Deterministic_candidate shape ->
        (match prem.it with
        | RulePr (_, _, _, exp) ->
          Premise_rule_deterministic.lower
            names
            ctx
            env
            ~bound_vars
            ~factor_head_domain:factor_head_domains
            origin
            prem
            rel_id
            exp
            shape
        | _ ->
          ( unsupported_prem ctx env ~bound_vars origin
              "Premise/RulePr/deterministic" prem
              "deterministic relation premise lowering expected a RulePr AST node"
          , names ))
      | Relation_shape.Execution _ ->
        let annotation =
          if Analysis.Function_graph.relation_has_maude_equational_view relation
          then
            "the annotation requires promotion of the enclosing DecD to a rewrite wrapper"
          else
            "no hint(maude_equational_view) right-uniqueness contract permits that promotion"
        in
        ( unsupported_prem ctx env ~bound_vars origin
            "Premise/RulePr/execution" prem
            ("execution relation premise cannot be emitted inside eq/ceq/cmb conditions; structural relation classification is "
           ^ relation_shape.Relation_shape.marker_text ^ "; " ^ annotation)
        , names )
      | Relation_shape.Unknown reason ->
        ( unsupported_prem ctx env ~bound_vars origin
            "Premise/RulePr/unknown" prem
            ("relation premise marker is not classified as validation, deterministic, or execution; structural relation classification is "
           ^ relation_shape.Relation_shape.marker_text
           ^ "; "
           ^ reason)
        , names )
