open Il.Ast
open Maude_ir
open Util.Source

open Reld_result
open Reld_rule_lowering

let translate_rule
    ctx
    rel_origin
    op_name
    relation_id
    relation_kind
    relation_mixop
    components
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let names = local_names_for_rule rule in
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      { empty with diagnostics = hint_diags @ marker_diags }
    else
      let expected_typs = Relation_shape.component_typs components in
      let components_opt, arity_diags =
        exp_components_match ctx origin "RelD/runtime-predicate/RuleD/arity" expected_typs exp
      in
      let env, var_decls, bind_diags, names =
        translate_rule_binds ctx origin names binds
      in
      (match components_opt with
      | None ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags
        }
      | Some body_components ->
        let (lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags), names =
          lower_pattern_components_named names ctx env origin body_components
        in
        (match lhs_terms_opt with
        | None ->
          { statements = var_decls
          ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
          }
        | Some lhs_terms ->
          let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
          let premise_translation, _names =
            Premise_translate.translate_premises_named
              names
              ctx
              env
              ~bound_conditions:lhs_guards
              ~escape_source_ids:(Source_free_vars.exp_and_note_ids exp)
              ~bound_terms:lhs_terms
              origin
              prems
          in
          (match premise_translation with
          | Premise_result.Blocked diagnostics
          | Deferred (_, diagnostics) ->
            { statements = var_decls
            ; diagnostics =
                hint_diags @ bind_diags @ arity_diags @ lhs_diags
                @ diagnostics
            }
          | Complete premise_result ->
          let diagnostics =
            hint_diags
            @ bind_diags @ arity_diags @ lhs_diags
            @ Premise_result.diagnostics premise_result
          in
          if Premise_result.rule_conditions premise_result <> [] then
            { statements = var_decls
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/runtime-predicate/rewrite-premise"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "runtime predicate RelD rules cannot use rewrite conditions in this helper-free slice"
                      ~suggestion:
                        "Promote the enclosing predicate/definition to a rewrite-dependent helper before lowering this rule"
                      ()
                  ]
            }
          else if Premise_result.has_else premise_result then
            { statements = var_decls
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/runtime-predicate/ElsePr"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "runtime predicate ElsePr requires a proven executable/decidable complement before [owise] can be used soundly"
                      ~suggestion:
                        "Keep this source otherwise branch Unsupported until a source-derived predicate complement or total false fallback is implemented"
                      ()
                  ]
            }
          else if has_fatal diagnostics then
            { statements = var_decls; diagnostics }
          else
            let lhs = relation_call op_name lhs_terms in
            let pattern_certificate =
              Premise_result.condition_pattern_certificate
                ~declarations:var_decls ctx premise_result
            in
            let conditions =
              lhs_guards @ Premise_result.eq_conditions premise_result
              |> Condition_closure.normalize_binding_conditions
                   ~constructor_op:pattern_certificate
                   lhs_terms
              |> dedup_conditions
            in
            let admissibility_diags =
              Condition_admissibility.ceq_admissibility_diagnostics
                ~constructor_op:pattern_certificate
                ctx
                origin
                lhs
                (Const "true")
                conditions
            in
            if has_fatal admissibility_diags then
              { statements = var_decls; diagnostics = diagnostics @ admissibility_diags }
            else
              { statements =
                  var_decls
                  @ [ gen origin (ceq lhs (Const "true") conditions) ]
              ; diagnostics
              })) )

let blocker_text
    (blocker : Analysis.Function_graph.runtime_search_blocker)
  =
  let rule =
    match blocker.Analysis.Function_graph.rule_id with
    | None -> ""
    | Some rule_id -> "/" ^ rule_id
  in
  let premise =
    match
      ( blocker.Analysis.Function_graph.premise_constructor
      , blocker.Analysis.Function_graph.premise_source_echo )
    with
    | None, None -> ""
    | Some constructor, None -> " via " ^ constructor
    | None, Some source -> " via premise `" ^ source ^ "`"
    | Some constructor, Some source -> " via " ^ constructor ^ " `" ^ source ^ "`"
  in
  Printf.sprintf
    "%s%s%s [%s]: %s"
    blocker.Analysis.Function_graph.relation_id
    rule
    premise
    blocker.Analysis.Function_graph.constructor
    blocker.Analysis.Function_graph.reason

let format_blockers blockers =
  let rec take n values =
    match n, values with
    | 0, rest -> [], List.length rest
    | _, [] -> [], 0
    | n, value :: rest ->
      let kept, omitted = take (n - 1) rest in
      value :: kept, omitted
  in
  let kept, omitted = take 8 (List.map blocker_text blockers) in
  let rendered = String.concat "; " kept in
  if omitted = 0 then rendered
  else if rendered = "" then Printf.sprintf "... and %d more" omitted
  else Printf.sprintf "%s; ... and %d more" rendered omitted

let dependency_diagnostics ctx origin id =
  match
    Analysis.Function_graph.runtime_predicate_dependency_completeness
      (Context.function_graph ctx)
      id.it
  with
  | Analysis.Function_graph.Runtime_predicate_dependencies_complete _ -> []
  | Analysis.Function_graph.Runtime_predicate_dependencies_incomplete
      { closure; blockers; _ } ->
    [ unsupported
        ~ctx
        ~origin
        ~constructor:"RelD/runtime-predicate/incomplete-dependency"
        ~reason:
          ("runtime predicate relation depends on runtime-demanded predicate relation(s) whose source predicate closure is not complete; dependency closure: "
           ^ String.concat " -> " closure
           ^ "; blockers: "
           ^ format_blockers blockers)
        ~suggestion:
          "Emit only the predicate op until every runtime predicate dependency can be lowered source-completely; partial true equations would turn missing source branches into false Maude results"
        ()
    ]

let source_rule_of_runtime_search_rule
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  { Runtime_witness_proof.identity = rule.identity
  ; relation_id = rule.relation_id
  ; rule_id = rule.rule_id
  ; origin = rule.origin
  ; source_echo = rule.source_echo
  ; head = rule.head
  ; prems = rule.prems
  }

let rule_has_transitive_witness_domain rule =
  rule
  |> source_rule_of_runtime_search_rule
  |> Runtime_witness_proof.transitive_domain
  |> Option.is_some

let rule_has_target_guided_witness rule =
  rule
  |> source_rule_of_runtime_search_rule
  |> Runtime_witness_proof.target_chain
  |> Option.is_some

let needs_truth_search ctx id =
  match
    Analysis.Function_graph.runtime_predicate_search_plan
      (Context.function_graph ctx)
      id.it
  with
  | Analysis.Function_graph.Runtime_search_no_shape_blockers { rules; _ }
  | Analysis.Function_graph.Runtime_search_blocked_plan { rules; _ } ->
    List.exists
      (fun rule ->
        rule_has_transitive_witness_domain rule
        || rule_has_target_guided_witness rule)
      rules

let translate ctx origin id relation_kind relation_mixop runtime_reason components rules =
  let typs = Relation_shape.component_typs components in
  let input_sorts_opt, input_diags =
    component_sorts ctx origin "RelD/runtime-predicate/input" typs
  in
  if has_fatal input_diags then
    { empty with diagnostics = input_diags }
  else
    match input_sorts_opt with
    | Some input_sorts ->
      let op_name = Naming.relation_op id in
      let op_decl =
        gen origin
          (op
             op_name
             (List.map sort_ref input_sorts)
             (sort "Bool"))
      in
      let dependency_diags = dependency_diagnostics ctx origin id in
      if needs_truth_search ctx id then
        { statements = [ op_decl ]
        ; diagnostics = input_diags @ dependency_diags
        }
      else
        let rules_output =
          rules
          |> List.mapi (fun index rule ->
            translate_rule
              ctx
              origin
              op_name
              id.it
              relation_kind
              relation_mixop
              components
              (index + 1)
              rule)
          |> List.fold_left append empty
        in
        let diagnostics =
          input_diags @ dependency_diags @ rules_output.diagnostics
        in
        let statements =
          if has_fatal diagnostics then
            [ op_decl ]
          else
            op_decl :: rules_output.statements
        in
        { statements; diagnostics }
    | None ->
      { empty with
        diagnostics =
          input_diags
          @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"RelD/runtime-predicate"
                ~reason:
                  (runtime_reason
                   ^ "; runtime predicate relation arguments could not be assigned Maude carriers")
                ~suggestion:
                  "Add source-preserving carrier support before emitting this runtime predicate relation"
                ()
            ]
      }
