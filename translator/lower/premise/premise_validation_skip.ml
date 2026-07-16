open Il.Ast
open Util.Source


(* Validated runtime configuration policy.

   These functions do not lower validation premises to Maude.  They only decide
   when a validation-only witness is local to other validation premises and can
   be discharged because the official Wasm validator already checked it before
   the runtime/model-checking configuration is built. *)

let skipped_prem = Premise_diagnostic.skipped_prem

let structural_rule_reason ctx rel_id mixop =
  if Option.is_some (Context.runtime_relation_use_reason ctx rel_id.it) then
    None
  else match
    Analysis.Function_graph.find_relation
      (Context.function_graph ctx)
      rel_id.it
  with
  | None -> None
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    if local_kind <> relation_shape.Relation_shape.marker
       || not (Analysis.Relation_graph.eq_mixop relation.mixop mixop)
    then
      None
    else
      match relation_shape.Relation_shape.decision with
      | Relation_shape.Static_validation reason -> Some reason
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> None

type body =
  { reasons : string list
  ; has_relation : bool
  }

let body reason has_relation =
  { reasons = [ reason ]; has_relation }

let rec iter_body ctx prem =
  match prem.it with
  | IfPr _ -> Some (body "source side condition" false)
  | RulePr (rel_id, [], mixop, _) ->
    (match structural_rule_reason ctx rel_id mixop with
    | Some reason -> Some (body reason true)
    | None -> None)
  | RulePr (_, _ :: _, _, _) -> None
  | IterPr (body, _) -> iter_body ctx body
  | NegPr _ | LetPr _ | ElsePr -> None

let enclosing_relation_id ctx =
  match Context.enclosing_path ctx with
  | relation_id :: _ -> Some relation_id
  | [] -> None

let enclosing_static_relation ctx =
  match enclosing_relation_id ctx with
  | None -> false
  | Some relation_id ->
    (match
       Analysis.Function_graph.find_relation
         (Context.function_graph ctx)
         relation_id
     with
    | Some relation ->
      (match (Relation_shape.of_relation relation).Relation_shape.decision with
      | Relation_shape.Static_validation _ -> true
      | Relation_shape.Runtime_predicate _
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> false)
    | None -> false)

let unbound_external_source_ids env ~bound_vars local_ids prem =
  Source_free_vars.prem_and_note_ids prem
  |> List.filter (fun id ->
    not (List.mem id local_ids)
    && not (Premise_state.source_id_is_bound env bound_vars id))
  |> List.sort_uniq String.compare

let iter_local_source_ids = function
  | ListN (_, Some id) -> [ id.it ]
  | Opt | List | List1 | ListN (_, None) -> []

let validation_local_generator_ids env ~bound_vars generators =
  generators
  |> List.filter_map (fun (id, source_exp) ->
    let source_ids = Source_free_vars.exp_and_note_ids source_exp in
    if source_ids = []
       || List.exists
            (fun source_id ->
              not (Premise_state.source_id_is_bound env bound_vars source_id))
            source_ids
    then
      Some id.it
    else
      None)
  |> List.sort_uniq String.compare

let future_runtime_source_ids ctx prems =
  prems
  |> List.filter (fun prem ->
    match iter_body ctx prem with
    | Some _ -> false
    | None -> true)
  |> List.concat_map Source_free_vars.prem_and_note_ids
  |> List.sort_uniq String.compare

let skip_eligible_premise ctx prem =
  match prem.it with
  | RulePr (rel_id, [], mixop, _) ->
    Option.is_some (structural_rule_reason ctx rel_id mixop)
  | RulePr (_, _ :: _, _, _) -> false
  | IterPr (body, _) -> Option.is_some (iter_body ctx body)
  | IfPr _ | LetPr _ | ElsePr | NegPr _ -> false

let future_skipped_source_ids ctx prems =
  prems
  |> List.filter (skip_eligible_premise ctx)
  |> List.concat_map Source_free_vars.prem_and_note_ids
  |> List.sort_uniq String.compare

let mixop_has_validation_subtyping_marker mixop =
  Xl.Mixop.flatten mixop
  |> List.exists (fun atoms ->
    atoms
    |> List.exists (fun atom ->
      match atom.it with
      | Xl.Atom.TurnstileSub | Xl.Atom.Sub -> true
      | _ -> false))

let enclosing_relation_has_subtyping_marker ctx =
  match enclosing_relation_id ctx with
  | None -> false
  | Some relation_id ->
    (match
       Analysis.Function_graph.find_relation
         (Context.function_graph ctx)
         relation_id
     with
    | None -> false
    | Some relation -> mixop_has_validation_subtyping_marker relation.mixop)

let try_skip_rulepr_validation_witness
    ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem rel_id mixop =
  match structural_rule_reason ctx rel_id mixop with
  | None -> None
  | Some reason ->
    let enclosing_id = enclosing_relation_id ctx in
    if not (enclosing_static_relation ctx) then
      None
    else if mixop_has_validation_subtyping_marker mixop then
      None
    else if enclosing_relation_has_subtyping_marker ctx then
      None
    else if enclosing_id = Some rel_id.it then
      None
    else
      let unbound_ids = unbound_external_source_ids env ~bound_vars [] prem in
      if unbound_ids = [] then
        None
      else
        let later_runtime_ids = future_runtime_source_ids ctx future_prems in
        let later_static_ids = future_skipped_source_ids ctx future_prems in
        let later_ids =
          future_prems
          |> List.concat_map Source_free_vars.prem_and_note_ids
          |> List.sort_uniq String.compare
        in
        let escaping_ids =
          unbound_ids
          |> List.filter (fun id ->
            List.mem id escape_source_ids
            || List.mem id later_runtime_ids
            || (List.mem id later_ids && not (List.mem id later_static_ids)))
        in
        if escaping_ids <> [] then
          None
        else
          let reason =
            "static validation relation premise is discharged because the runtime starts from an initial configuration checked by the official validator; structural relation classification is "
            ^ reason
            ^ "; validation-local variable(s) are used only by later static-validation premises and do not escape runtime output or later runtime/non-validation conditions: "
            ^ String.concat ", " unbound_ids
          in
          Some
            (skipped_prem ctx env ~bound_vars origin
               "Premise/RulePr/static-validation"
               prem
               reason
               "Keep this validation-only witness premise in diagnostics/metadata; emit no runtime Maude condition for the local validation witness")

let try_skip_iterpr_validation_witness
    ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators =
  match iter_body ctx body with
  | None -> None
  | Some body_info ->
    let scoped_local_ids =
      iter_local_source_ids iter
      @ (generators |> List.map (fun (id, _source) -> id.it))
      |> List.sort_uniq String.compare
    in
    let guarded_local_ids =
      iter_local_source_ids iter
      @ validation_local_generator_ids env ~bound_vars generators
      |> List.sort_uniq String.compare
    in
    let unbound_ids =
      unbound_external_source_ids env ~bound_vars scoped_local_ids prem
    in
    let enclosing_static = enclosing_static_relation ctx in
    if (not body_info.has_relation) && not enclosing_static then
      None
    else
      let later_ids = future_runtime_source_ids ctx future_prems in
      let guarded_ids =
        guarded_local_ids @ unbound_ids |> List.sort_uniq String.compare
      in
      if enclosing_static && guarded_ids = [] then
        None
      else
        let escaping_ids =
          guarded_ids
          |> List.filter (fun id ->
            List.mem id escape_source_ids || List.mem id later_ids)
        in
        if escaping_ids <> [] then
          None
        else
          let reason =
            "iterated static validation premise is discharged because the runtime starts from an initial configuration checked by the official validator; body structural classification is "
            ^ (body_info.reasons
               |> List.sort_uniq String.compare
               |> String.concat "; ")
            ^ "; validation-local variable(s) do not escape runtime output or later runtime/non-validation conditions: "
            ^
            match guarded_ids with
            | [] -> "<none>"
            | ids -> String.concat ", " ids
          in
          Some
            (skipped_prem ctx env ~bound_vars origin
               "Premise/IterPr/static-validation"
               prem
               reason
               "Keep the iterated source premise in diagnostics/metadata; emit no runtime Maude condition for this validation-only IterPr")
