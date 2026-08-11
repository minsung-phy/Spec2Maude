open Il.Ast
open Maude_ir
open Util.Source

open Reld_result
open Reld_rule_lowering

let has_else_premise prems =
  prems
  |> List.exists (fun prem ->
    match prem.it with
    | ElsePr -> true
    | _ -> false)

let without_else_premises prems =
  prems
  |> List.filter (fun prem ->
    match prem.it with
    | ElsePr -> false
    | _ -> true)

let condition_vars = function
  | EqCond (left, right) | MatchCond (left, right) ->
    Head_specialization.term_vars left @ Head_specialization.term_vars right
  | BoolCond term | MembershipCond (term, _) ->
    Head_specialization.term_vars term

let discharge_established_guards ~lhs_vars ~established conditions =
  let established_on_lhs condition =
    List.mem condition established
    && condition_vars condition
       |> List.for_all (fun var -> List.mem var lhs_vars)
  in
  conditions
  |> List.filter (function
       | EqCondition ((EqCond _ | BoolCond _ | MembershipCond _) as condition) ->
         not (established_on_lhs condition)
       | EqCondition (MatchCond _) | RewriteCond _ -> true)

let is_whole_typecheck subject = function
  | BoolCond (App ("typecheck", [ guarded; _ ])) -> guarded = subject
  | BoolCond _ | EqCond _ | MatchCond _ | MembershipCond _ -> false

let schedule_context_blocks blocks =
  let direct, contextual =
    List.partition (fun (is_context, _output) -> not is_context) blocks
  in
  let statements blocks =
    blocks
    |> List.concat_map (fun (_is_context, output) -> output.statements)
  in
  let diagnostics =
    blocks
    |> List.concat_map (fun (_is_context, output) -> output.diagnostics)
  in
  { statements = statements direct @ statements contextual
  ; diagnostics
  }

let translate_rule
    ctx
    rel_origin
    op_name
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    input_sorts
    output_sorts
    context_certificate
    previous_rules
    index
    rule
  =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let names = local_names_for_rule rule in
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id.it rule_id in
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
    let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
    let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
    let expected_typs = input_typs @ output_typs in
    let components_opt, arity_diags =
      exp_components_match ctx origin "RelD/execution/RuleD/arity" expected_typs exp
    in
    let env, var_decls, bind_diags, names =
      translate_rule_binds ctx origin names binds
    in
    (match components_opt with
    | None ->
      { statements = var_decls
      ; diagnostics = hint_diags @ bind_diags @ arity_diags
      }
    | Some components ->
      let input_count = List.length input_typs in
      let rec split n left right =
        if n = 0 then List.rev left, right
        else
          match right with
          | [] -> List.rev left, []
          | item :: rest -> split (n - 1) (item :: left) rest
      in
      let input_exps, output_exps = split input_count [] components in
      let (lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags), names =
        lower_validated_input_components_named
          names ctx env origin input_exps
      in
      (match lhs_terms_opt with
      | Some lhs_terms ->
        let head_facts = lhs_guards in
        let env =
          add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings
        in
        let has_else = has_else_premise prems in
        let else_result =
          if has_else then
            Reld_enabledness.complement
              ctx
              rel_origin
              relation_id
              relation_kind
              relation_mixop
              shape
              input_sorts
              origin
              lhs_terms
              lhs_guards
              previous_rules
          else
            { Reld_enabledness.output = empty
            ; alternatives =
                [ { Reld_enabledness.conditions = []; established = [] } ]
            ; support_statements = []
            }
        in
        let else_output = else_result.Reld_enabledness.output in
        let else_alternatives = else_result.alternatives in
        let premise_translation, names =
          Reld_execution_premise.translate_premises_named
            names
            ctx
            env
            ~bound_conditions:lhs_guards
            ~head_facts
            ~escape_source_ids:
              (output_exps
               |> List.concat_map Source_free_vars.exp_and_note_ids
               |> List.sort_uniq String.compare)
            ~bound_terms:lhs_terms
            origin
            (without_else_premises prems)
        in
        (match premise_translation with
        | Premise_result.Blocked diagnostics
        | Deferred (_, diagnostics) ->
          { statements = var_decls
          ; diagnostics =
              hint_diags @ bind_diags @ arity_diags @ lhs_diags
              @ else_output.diagnostics @ diagnostics
          }
        | Complete premise_result ->
        let output_terms_opt, output_guards, output_diags =
          lower_value_components
            ctx
            (Premise_result.env_after premise_result)
            origin
            "rhs"
            output_exps
        in
        let diagnostics =
          hint_diags
          @ bind_diags @ arity_diags @ lhs_diags @ output_diags
          @ else_output.diagnostics @ Premise_result.diagnostics premise_result
        in
        if has_fatal diagnostics then
          { statements = var_decls; diagnostics }
        else
          (match output_terms_opt with
          | Some output_terms
            when List.length output_terms = List.length output_sorts ->
            let rhs_term = tuple_carrier output_sorts output_terms in
            let lhs_terms, rhs_term, context, context_statements =
              match context_certificate with
              | None -> lhs_terms, rhs_term, None, []
              | Some certificate ->
                (match
                   Reld_context.lower ctx origin names env certificate
                 with
                | None -> lhs_terms, rhs_term, None, []
                | Some context ->
                  Reld_context.specialize_terms context lhs_terms,
                  Reld_context.specialize_term context rhs_term,
                  Some context,
                  Reld_context.statements context)
            in
            let context_conditions =
              match context with
              | None -> []
              | Some context -> [ Reld_context.membership context ]
            in
            let output_guards =
              match context with
              | None -> output_guards
              | Some context ->
                Reld_context.specialize_guards context output_guards
            in
            let output_guards =
              match context with
              | Some _ ->
                (* The context certificate preserves the input prefix/suffix
                   and obtains the new state/focus from the recursive relation
                   premise.  From the validated-input invariant, recursive
                   output typing therefore implies typing of the reassembled
                   source RHS. *)
                List.filter
                  (fun guard -> not (is_whole_typecheck rhs_term guard))
                  output_guards
              | None -> output_guards
            in
            let lhs = relation_call op_name lhs_terms in
            let pattern_certificate =
              Condition_pattern_certificate.union
                (Premise_result.condition_pattern_certificate
                   ~declarations:var_decls ctx premise_result)
                (Condition_pattern_certificate.generated
                   (context_statements
                    @ else_output.statements
                    @ else_result.support_statements))
            in
            let specialize_conditions conditions =
              match context with
              | None -> conditions
              | Some context ->
                Reld_context.specialize_conditions context conditions
            in
            let alternatives =
              else_alternatives
              |> List.mapi (fun alternative_index else_alternative ->
                let lhs_vars =
                  lhs_terms
                  |> List.concat_map Head_specialization.term_vars
                  |> List.sort_uniq String.compare
                in
                let else_conditions =
                  else_alternative.Reld_enabledness.conditions
                in
                let output_conditions =
                  List.map (fun condition -> EqCondition condition) output_guards
                in
                let premise_conditions =
                  Premise_result.rule_conditions premise_result
                in
                let raw_lhs_conditions =
                  List.map (fun condition -> EqCondition condition) lhs_guards
                in
                let lhs_conditions =
                  specialize_conditions raw_lhs_conditions
                in
                let source_rewrites =
                  premise_conditions
                  |> List.filter (function
                    | RewriteCond _ -> true
                    | EqCondition _ -> false)
                in
                let source_decisions =
                  source_rewrites
                  @ (Premise_result.source_condition_certificates premise_result
                   |> List.concat_map Source_condition_certificate.positive
                   |> List.map (fun condition -> EqCondition condition))
                  @ List.filter_map
                      (function
                        | EqCondition _ as condition -> Some condition
                        | RewriteCond _ -> None)
                      else_conditions
                  |> specialize_conditions
                in
                let conditions =
                  context_conditions
                  @ raw_lhs_conditions
                  @ premise_conditions
                  @ else_conditions
                  @ output_conditions
                  |> specialize_conditions
                  |> Validated_guard_certificate.discharge
                       ctx
                       (Premise_result.env_after premise_result)
                       ~lhs_terms
                  |> Condition_closure.normalize_rule_conditions
                       ~constructor_op:pattern_certificate
                       ~source_decisions
                       ~domain_guards:lhs_conditions
                       [ lhs ]
                  |> dedup_rule_conditions
                  |> discharge_established_guards
                       ~lhs_vars
                       ~established:
                         else_alternative.Reld_enabledness.established
                in
                let diagnostics =
                  Condition_admissibility.crl_admissibility_diagnostics
                    ~constructor_op:pattern_certificate
                    ctx origin lhs rhs_term conditions
                in
                let label =
                  let base = rule_label relation_id rule_id index in
                  if List.length else_alternatives = 1 then base
                  else base ^ "-alt-" ^ string_of_int (alternative_index + 1)
                in
                gen origin (crl ~label lhs rhs_term conditions), diagnostics)
            in
            let admissibility_diags = List.concat_map snd alternatives in
            if has_fatal admissibility_diags then
              { statements = var_decls
              ; diagnostics = diagnostics @ admissibility_diags
              }
            else
              let registry_diags =
                (context_statements
                 @ List.map fst alternatives)
                |> List.concat_map
                     (generated_statement_diagnostics
                        ~pattern_certificate ctx)
              in
              if has_fatal registry_diags then
                { statements = []
                ; diagnostics = diagnostics @ registry_diags
                }
              else
                { statements =
                    var_decls
                    @ context_statements
                    @ else_output.statements
                    @ List.map fst alternatives
                ; diagnostics
                }
          | Some _ ->
            { statements = var_decls
            ; diagnostics =
                diagnostics
                @ [ unsupported
                      ~ctx
                      ~origin
                      ~constructor:"RelD/execution/output"
                      ~source_echo:(Il.Print.string_of_rule rule)
                      ~reason:
                        "execution relation lowering currently supports exactly one output component; multi-output execution rules remain Unsupported"
                      ()
                  ]
            }
          | None -> { statements = var_decls; diagnostics }))
      | _ ->
        { statements = var_decls
        ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
        }))

let translate ctx origin id relation_kind relation_mixop shape rules =
  let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
  let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
  let input_sorts_opt, input_diags =
    component_sorts ctx origin "RelD/execution/input" input_typs
  in
  let output_sorts_opt, output_diags =
    component_sorts ctx origin "RelD/execution/output" output_typs
  in
  let diagnostics = input_diags @ output_diags in
  if has_fatal diagnostics then
    { empty with diagnostics }
  else
    match input_sorts_opt, output_sorts_opt with
    | Some input_sorts, Some output_sorts ->
      let op_name = Naming.relation_op id in
      let conf_sort = relation_conf_sort id in
      let output_sort = execution_output_sort output_sorts in
      let header =
        [ gen origin (sort_decl conf_sort)
        ; gen origin (subsort output_sort conf_sort)
        ; gen origin
            (op
               ~attrs:(frozen_all (List.length input_sorts))
               op_name
               (List.map sort_ref input_sorts)
               conf_sort)
        ]
      in
      let rules_output =
        let rec loop previous index translated = function
          | [] -> List.rev translated
          | rule :: rest ->
            let context_certificate =
              Execution_context_certificate.certify id rule
            in
            let current =
              translate_rule
                ctx
                origin
                op_name
                id
                relation_kind
                relation_mixop
                shape
                input_sorts
                output_sorts
                context_certificate
                previous
                index
                rule
            in
            let is_context = Option.is_some context_certificate in
            loop
              (previous @ [ rule ])
              (index + 1)
              ((is_context, current) :: translated)
              rest
        in
        loop [] 1 [] rules |> schedule_context_blocks
      in
      { statements = header @ dedup_generated rules_output.statements
      ; diagnostics = diagnostics @ rules_output.diagnostics
      }
    | _ -> { empty with diagnostics }
