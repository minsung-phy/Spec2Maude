open Maude_ir
open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_prem = Premise_diagnostic.source_echo_prem
let unsupported_prem = Premise_diagnostic.unsupported_prem

let add_vars vars bound =
  vars
  |> List.fold_left
       (fun bound var -> if List.mem var bound then bound else var :: bound)
       bound

let split_prefix count items =
  let rec split n left right =
    if n = 0 then List.rev left, right
    else
      match right with
      | [] -> List.rev left, []
      | item :: rest -> split (n - 1) (item :: left) rest
  in
  split count [] items

let lower ctx env ~bound_vars origin prem rel_id exp
    (shape : Relation_shape.deterministic_shape) =
  let input_count = List.length shape.inputs in
  let expected_count = input_count + 1 in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic/arity" prem
      (Printf.sprintf
         "deterministic relation premise does not match the referenced RelD signature with %d input component(s) and one output component without flattening source tuple structure"
         input_count)
  | Some components ->
    let input_exps, output_exps = split_prefix input_count components in
    match output_exps with
    | [ output_exp ] ->
      let input_terms_opt, input_guards, input_diags =
        Premise_rule_support.lower_input_values ctx env origin input_exps
      in
      let output_pattern =
        Expr_translate.lower_pattern_with_bindings ctx env origin output_exp
      in
      let output_sort_opt =
        Expr_translate.carrier_sort_of_typ shape.Relation_shape.output.typ
      in
      (match input_terms_opt, output_pattern.pattern_term, output_sort_opt with
      | Some input_terms, Some output_term, Some output_sort ->
        let binding_needed reason suggestion =
          { (empty_with_env ~bound_vars env) with
            eq_conditions = input_guards @ output_pattern.pattern_guards
          ; diagnostics =
              input_diags @ output_pattern.pattern_diagnostics
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/RulePr/deterministic/binding-needed"
                    ~source_echo:(source_echo_prem prem)
                    ~reason
                    ~suggestion
                    ()
                ]
          }
        in
        (match
           Condition_closure.conditions_admissible_bound bound_vars input_guards
         with
        | None ->
          binding_needed
            "deterministic relation input guards are not admissible before the relation result matching condition"
            "Bind the deterministic relation inputs through earlier source premises before calling the deterministic relation"
        | Some guard_bound ->
          let subject = Premise_rule_support.relation_call rel_id input_terms in
          let missing =
            Condition_closure.term_vars subject
            |> List.filter (fun var -> not (List.mem var guard_bound))
            |> List.sort_uniq String.compare
          in
          if missing <> [] then
            binding_needed
              ("deterministic relation input value(s) are not bound before the result matching condition: "
               ^ String.concat ", " missing)
              "Keep this RulePr Unsupported until the source provides a prior binding premise or a source-derived search helper is implemented"
          else
            let result_var =
              Premise_rule_support.fresh_result_var
                ~fallback:"DET"
                ~label:"deterministic-result"
                origin
                rel_id
                output_sort
            in
            let result_condition = MatchCond (result_var, subject) in
            let condition =
              let bound_after_result =
                add_vars (Condition_closure.term_vars result_var) guard_bound
              in
              Premise_rule_support.result_output_condition
                bound_after_result
                output_term
                result_var
            in
            let env_after =
              Premise_state.add_introduced_bindings
                env
                output_pattern.introduced_bindings
            in
            let conditions =
              input_guards @ [ result_condition; condition ]
              @ output_pattern.pattern_guards
            in
            { (empty_with_env
                 ~bound_vars:
                   (Condition_closure.conditions_bound_vars bound_vars conditions)
                 env_after) with
              eq_conditions = conditions
            ; diagnostics = input_diags @ output_pattern.pattern_diagnostics
            })
      | _ ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = input_guards @ output_pattern.pattern_guards
        ; diagnostics =
            input_diags @ output_pattern.pattern_diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/RulePr/deterministic/output"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "deterministic relation premise requires all input expressions to lower as values, the output component to lower as a source-shaped pattern, and the output carrier sort to be known"
                  ~suggestion:
                    "Keep this premise Unsupported until a source-preserving inverse/pattern helper exists for the unsupported component"
                  ()
              ]
        })
    | _ ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic/output" prem
        "deterministic relation premise requires exactly one output component in this helper-free slice"
