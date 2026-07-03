open Il.Ast
open Maude_ir
open Util.Source

include Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_prem = Premise_diagnostic.source_echo_prem
let origin_for_premise = Premise_diagnostic.origin_for_premise
let origin_for_if_conjunct = Premise_diagnostic.origin_for_if_conjunct
let unsupported_prem = Premise_diagnostic.unsupported_prem
let unsupported_rulepr_args = Premise_diagnostic.unsupported_rulepr_args
let skipped_prem = Premise_diagnostic.skipped_prem

let conditions_bound_vars = Condition_closure.conditions_bound_vars

let with_conditions = Premise_state.with_conditions

let diagnostics_have_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let premise_result_has_fatal result =
  diagnostics_have_fatal result.diagnostics

let result_is_deferrable_listn_admissibility result =
  result.diagnostics
  |> List.exists (fun diagnostic ->
    Diagnostics.is_fatal diagnostic
    && diagnostic.Diagnostics.constructor = "Expr/IterE/ListN/premise-admissibility")

let add_introduced_bindings = Premise_state.add_introduced_bindings


let lower_bool_premise ctx env ~bound_vars origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  match lowered.term with
  | Some term ->
    with_conditions env bound_vars (lowered.guards @ [ BoolCond term ]) lowered.diagnostics
  | None -> { (empty_with_env ~bound_vars env) with diagnostics = lowered.diagnostics }

let rec lower_if_premise ctx env ~bound_vars origin (exp : exp) =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    let left_origin = origin_for_if_conjunct origin "and-left" left in
    let right_origin = origin_for_if_conjunct origin "and-right" right in
    let left_result = lower_if_premise ctx env ~bound_vars left_origin left in
    let right_result =
      lower_if_premise
        ctx
        left_result.env_after
        ~bound_vars:left_result.bound_vars_after
        right_origin
        right
    in
    append left_result right_result
  | CmpE (`EqOp, _, left, right) ->
    Premise_eq_binding.lower_ifpr_eq ctx env ~bound_vars origin exp left right
  | MemE (left, right) ->
    (match
       Premise_membership.try_lower_ifpr_meme_binding
         ctx
         env
         ~bound_vars
         origin
         exp
         left
         right
     with
    | Some result -> result
    | None -> lower_bool_premise ctx env ~bound_vars origin exp)
  | _ -> lower_bool_premise ctx env ~bound_vars origin exp

let lower_rule_premise
    ctx
    env
    ~allow_runtime_search
    ~bound_vars
    ~blocked_witness_source_ids
    ~future_prems
    ~escape_source_ids
    origin
    prem
    rel_id
    mixop =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id.it with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/unresolved" prem
      ("relation premise references `" ^ rel_id.it ^ "`, but no matching RelD was found in the source index")
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    if local_kind <> relation_shape.Relation_shape.marker then
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/mixop" prem
        ("source relation marker mismatch: referenced relation is `"
         ^ relation_shape.Relation_shape.marker_text
         ^ "`, but this RulePr local mixop is `"
         ^ Analysis.Relation_graph.string_of_relation_kind local_kind
         ^ "`")
    else if not (Analysis.Relation_graph.eq_mixop relation.mixop mixop) then
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/mixop-skeleton" prem
        ("source relation mixop skeleton mismatch: referenced RelD `"
         ^ rel_id.it
         ^ "` uses `"
         ^ Analysis.Relation_graph.mixop_shape_text relation.mixop
         ^ "`, but this RulePr uses `"
         ^ Analysis.Relation_graph.mixop_shape_text mixop
         ^ "`")
    else
    (match relation_shape.Relation_shape.decision with
    | Relation_shape.Static_validation _ ->
      (match
         Analysis.Function_graph.relation_runtime_demand_reason
           (Context.function_graph ctx)
           rel_id.it
       with
      | Some runtime_reason ->
        (match prem.it with
        | RulePr (_, _, _, exp) ->
          Premise_rule_runtime_predicate.lower
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
        | _ ->
          unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-demanded-predicate" prem
            ("relation is static by signature but runtime-demanded by the relation call graph: "
             ^ runtime_reason))
      | None ->
        skipped_prem ctx env ~bound_vars origin "Premise/RulePr/static-validation" prem
          ("static validation relation premise is discharged by the official validator in Runtime_after_external_validation; structural relation classification is "
           ^ relation_shape.Relation_shape.marker_text)
          "Keep the source premise in diagnostics/metadata; emit no runtime Maude condition for this validation-only premise")
    | Relation_shape.Runtime_predicate _ ->
      (match prem.it with
      | RulePr (_, _, _, exp) ->
        Premise_rule_runtime_predicate.lower
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
      | _ ->
        unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-predicate" prem
          "runtime predicate premise lowering expected a RulePr AST node")
    | Relation_shape.Deterministic_candidate shape ->
      (match prem.it with
      | RulePr (_, _, _, exp) ->
        Premise_rule_deterministic.lower
          ctx
          env
          ~bound_vars
          origin
          prem
          rel_id
          exp
          shape
      | _ ->
        unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic" prem
          "deterministic relation premise lowering expected a RulePr AST node")
    | Relation_shape.Execution shape ->
      if Analysis.Function_graph.relation_has_maude_equational_view relation then
        (match prem.it with
        | RulePr (_, _, _, exp) ->
          Premise_rule_equational_view.lower
            ctx
            env
            ~bound_vars
            origin
            prem
            rel_id
            exp
            shape
        | _ ->
          unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/equational-view" prem
            "annotated equational-view lowering expected a RulePr AST node")
      else
        unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/execution" prem
          ("execution relation premise cannot be emitted inside eq/ceq/cmb conditions; structural relation classification is "
           ^ relation_shape.Relation_shape.marker_text
           ^ ", so this requires RelD lowering plus rewrite-dependent DecD/crl helper support or an explicit maude_equational_view annotation")
    | Relation_shape.Unknown reason ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/unknown" prem
        ("relation premise marker is not classified as validation, deterministic, or execution; structural relation classification is "
         ^ relation_shape.Relation_shape.marker_text
         ^ "; "
         ^ reason))


let rec translate_premise
    ?(allow_runtime_search = false)
    ?(future_prems = [])
    ?(escape_source_ids = [])
    ?(blocked_witness_source_ids = [])
    ctx
    env
    ~bound_vars
    parent_origin
    prem =
  let origin = origin_for_premise parent_origin prem in
  let env = Expr_translate.with_condition_bound_vars env bound_vars in
  match prem.it with
  | IfPr exp -> lower_if_premise ctx env ~bound_vars origin exp
  | LetPr (quants, lhs, rhs) ->
    let ids =
      quants
      |> List.filter_map (fun quant ->
        match quant.it with
        | ExpP (id, _) -> Some id.it
        | TypP _ | DefP _ | GramP _ -> None)
    in
    let lhs_result = Expr_translate.lower_pattern_with_bindings ctx env origin lhs in
    let rhs_result = Expr_translate.lower_value ctx env origin rhs in
    (match lhs_result.pattern_term, rhs_result.term with
    | Some lhs_term, Some rhs ->
      let env_after =
        add_introduced_bindings ~ids env lhs_result.introduced_bindings
      in
      let conditions = rhs_result.guards @ [ MatchCond (lhs_term, rhs) ] @ lhs_result.pattern_guards in
      { (with_conditions
           env_after
           bound_vars
           conditions
           (lhs_result.pattern_diagnostics @ rhs_result.diagnostics))
        with
        let_bound_ids = [ ids ]
      }
    | _ ->
      { (empty_with_env ~bound_vars env) with
        let_bound_ids = [ ids ]
      ; diagnostics =
          lhs_result.pattern_diagnostics @ rhs_result.diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Premise/LetPr"
                ~source_echo:(source_echo_prem prem)
                ~reason:
                  ("LetPr could not be lowered; outbound ids preserved in premise metadata: "
                   ^ String.concat ", " ids)
                ()
            ]
      })
  | ElsePr -> { (empty_with_env ~bound_vars env) with has_else = true }
  | RulePr (rel_id, args, mixop, _exp) ->
    if args <> [] then
      unsupported_rulepr_args ctx env ~bound_vars origin prem rel_id args
    else
    (match
       Premise_runtime_after_external_validation_skip
       .try_skip_rulepr_validation_witness
         ctx
         env
         ~bound_vars
         ~future_prems
         ~escape_source_ids
         origin
         prem
         rel_id
         mixop
     with
    | Some result -> result
    | None ->
      lower_rule_premise
        ctx
        env
        ~allow_runtime_search
        ~bound_vars
        ~blocked_witness_source_ids
        ~future_prems
        ~escape_source_ids
        origin
        prem
        rel_id
        mixop)
  | IterPr (body, iterexp) ->
    Premise_iter.lower
      ~lower_body:(fun env ~bound_vars origin prem ->
        translate_premise ctx env ~bound_vars origin prem)
      ctx
      env
      ~bound_vars
      ~future_prems
      ~escape_source_ids
      origin
      ~prem
      ~body
      iterexp
  | NegPr _ ->
    unsupported_prem ctx env ~bound_vars origin "Premise/NegPr" prem
      "negated premises require a total Bool/complement helper, which is outside this pure DecD slice"

let translate_premises
    ?(allow_runtime_search = false)
    ctx env ?(bound_conditions = []) ?(escape_source_ids = []) ~bound_terms origin prems =
  let bound_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> normalize_vars
    |> fun vars -> conditions_bound_vars vars bound_conditions
  in
  let stalled_fatal_diagnostics stalled =
    stalled
    |> List.concat_map (fun (_prem, result) ->
      result.diagnostics |> List.filter Diagnostics.is_fatal)
  in
  let no_progress_result acc stalled =
    match stalled_fatal_diagnostics stalled with
    | _ :: _ as diagnostics -> { acc with diagnostics = acc.diagnostics @ diagnostics }
    | [] ->
      (match stalled with
      | [] -> acc
      | (prem, result) :: _ ->
        let prem_origin = origin_for_premise origin prem in
        { acc with
          diagnostics =
            acc.diagnostics @ result.diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin:prem_origin
                  ~constructor:"Premise/dependency-cycle"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "premise conditions cannot be ordered so every generated Maude condition uses only variables bound by the enclosing lhs or earlier admissible premises"
                  ~suggestion:
                    "Keep this premise block Unsupported until the source dependency cycle is removed or a source-derived rewrite/search helper can introduce the witness"
                  ()
              ]
        })
  in
  let rec pass acc progressed deferred = function
    | [] ->
      (match List.rev deferred with
      | [] -> acc
      | pending when progressed -> pass acc false [] (List.map fst pending)
      | stalled -> no_progress_result acc stalled)
    | prem :: rest ->
      let future_prems = rest @ (List.rev_map fst deferred) in
      let result =
        translate_premise
          ~allow_runtime_search
          ~future_prems
          ~escape_source_ids
          ~blocked_witness_source_ids:acc.blocked_witness_source_ids
          ctx
          acc.env_after
          ~bound_vars:acc.bound_vars_after
          origin
          prem
      in
      if premise_result_has_fatal result
         && result_is_deferrable_listn_admissibility result
      then
        pass acc progressed ((prem, result) :: deferred) rest
      else
        pass (append acc result) true deferred rest
  in
  let result = pass (empty_with_env ~bound_vars env) false [] prems in
  { result with
    env_after =
      Expr_translate.with_condition_bound_vars
        result.env_after
        result.bound_vars_after
  }
