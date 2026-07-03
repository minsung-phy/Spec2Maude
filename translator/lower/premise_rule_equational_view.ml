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
    (shape : Relation_shape.execution_shape) =
  let input_count = List.length shape.inputs in
  let output_count = List.length shape.outputs in
  let expected_count = input_count + output_count in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/equational-view/arity" prem
      (Printf.sprintf
         "annotated execution relation premise does not match the referenced RelD signature with %d input component(s) and %d output component(s) without flattening source tuple structure"
         input_count
         output_count)
  | Some components ->
    let input_exps, output_exps = split_prefix input_count components in
    let input_terms_opt, input_guards, input_diags =
      Premise_rule_support.lower_input_values ctx env origin input_exps
    in
    let output_patterns =
      output_exps
      |> List.map (Expr_translate.lower_pattern_with_bindings ctx env origin)
    in
    let output_terms =
      output_patterns
      |> List.filter_map
           (fun (pattern : Expr_translate.pattern_result) -> pattern.pattern_term)
    in
    let output_guards =
      output_patterns
      |> List.map (fun pattern -> pattern.Expr_translate.pattern_guards)
      |> List.concat
    in
    let output_diags =
      output_patterns
      |> List.map (fun pattern -> pattern.Expr_translate.pattern_diagnostics)
      |> List.concat
    in
    let output_bindings =
      output_patterns
      |> List.map (fun pattern -> pattern.Expr_translate.introduced_bindings)
      |> List.concat
    in
    let output_pattern_opt, tuple_errors =
      match output_terms with
      | [ term ] when output_count = 1 -> Some term, []
      | terms when List.length terms = output_count ->
        Premise_rule_support.tuple_pattern_from_components shape.outputs terms
      | _ -> None, []
    in
    let output_sort_opt =
      match shape.outputs with
      | [ component ] -> Expr_translate.carrier_sort_of_typ component.Relation_shape.typ
      | _ -> Some (sort "SpectecTerminal")
    in
    (match input_terms_opt, output_pattern_opt, output_sort_opt, tuple_errors with
    | Some input_terms, Some output_pattern, Some output_sort, [] ->
      let binding_needed reason suggestion =
        { (empty_with_env ~bound_vars env) with
          eq_conditions = input_guards @ output_guards
        ; diagnostics =
            input_diags @ output_diags
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/RulePr/equational-view/binding-needed"
                  ~source_echo:(source_echo_prem prem)
                  ~reason
                  ~suggestion
                  ()
              ]
        }
      in
      (match Condition_closure.conditions_admissible_bound bound_vars input_guards with
      | None ->
        binding_needed
          "annotated equational-view relation input guards are not admissible before the relation result matching condition"
          "Bind the relation inputs through earlier source premises before calling the annotated equational view"
      | Some guard_bound ->
        let subject =
          Premise_rule_support.relation_equational_view_call rel_id input_terms
        in
        let missing =
          Condition_closure.term_vars subject
          |> List.filter (fun var -> not (List.mem var guard_bound))
          |> List.sort_uniq String.compare
        in
        if missing <> [] then
          binding_needed
            ("annotated equational-view relation input value(s) are not bound before the result matching condition: "
             ^ String.concat ", " missing)
            "Keep this RulePr Unsupported until the source provides a prior binding premise or a source-derived search helper is implemented"
        else
          let result_var =
            Premise_rule_support.fresh_result_var
              ~fallback:"VIEW"
              ~label:"equational-view-result"
              origin
              rel_id
              output_sort
          in
          let result_condition = MatchCond (result_var, subject) in
          let bound_after_result =
            add_vars (Condition_closure.term_vars result_var) guard_bound
          in
          let output_condition =
            Premise_rule_support.result_output_condition
              bound_after_result
              output_pattern
              result_var
          in
          let env_after =
            Premise_state.add_introduced_bindings env output_bindings
          in
          let conditions =
            input_guards @ [ result_condition; output_condition ] @ output_guards
          in
          { (empty_with_env
               ~bound_vars:
                 (Condition_closure.conditions_bound_vars bound_vars conditions)
               env_after) with
            eq_conditions = conditions
          ; diagnostics = input_diags @ output_diags
          })
    | _ ->
      let tuple_error_reason =
        match tuple_errors with
        | [] ->
          "annotated equational-view relation requires all input expressions to lower as values and all output components to lower as source-shaped patterns"
        | errors -> String.concat "; " errors
      in
      { (empty_with_env ~bound_vars env) with
        eq_conditions = input_guards @ output_guards
      ; diagnostics =
          input_diags @ output_diags
          @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"Premise/RulePr/equational-view/output"
                ~source_echo:(source_echo_prem prem)
                ~reason:tuple_error_reason
                ~suggestion:
                  "Keep this premise Unsupported until the annotated equational view output can be represented by the existing tuple/sequence carrier"
                ()
            ]
      })
