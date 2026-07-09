open Il.Ast
open Util.Source

open Reld_common
open Reld_enabledness_direct_complement

let rule_id_opt rule_id =
  if rule_id.it = "" || rule_id.it = "_" then None else Some rule_id.it

let truth_search_helper_name ctx origin truth_request =
  Helper.request
    (Context.helpers ctx)
    { Helper.kind = Helper.Runtime_predicate_truth_search truth_request
    ; reason = Runtime_truth_search_helper.reason truth_request
    ; origin
    }

let truth_decision ctx origin truth_helper_name truth_request =
  let decision_request =
    { Runtime_truth_decision_helper.truth_helper_name
    ; truth_request
    }
  in
  let decision_helper_name =
    Helper.request
      (Context.helpers ctx)
      { Helper.kind =
          Helper.Runtime_predicate_truth_decision decision_request
      ; reason = Runtime_truth_decision_helper.reason decision_request
      ; origin
      }
  in
  { Runtime_enabledness_helper.helper_name = decision_helper_name
  ; request = decision_request
  }

let runtime_enabledness_complement
    ctx
    origin
    relation_id
    rule_id
    input_sorts
    current_lhs_terms
    lhs_terms
    lhs_guards
    (premise_result : Premise_result.result)
    truth_helper_name
    truth_request
    rule =
  let runtime_truth_decisions =
    [ truth_decision ctx origin truth_helper_name truth_request ]
  in
  let request =
    { Runtime_enabledness_helper.relation_id = relation_id.it
    ; rule_id = rule_id_opt rule_id
    ; call_terms = current_lhs_terms
    ; predecessor_terms = lhs_terms
    ; input_sorts
    ; lhs_conditions = lhs_guards
    ; premise_eq_conditions = premise_result.eq_conditions
    ; premise_rule_conditions = premise_result.rule_conditions
    ; runtime_search_requests = premise_result.runtime_search_requests
    ; runtime_truth_search_requests =
        premise_result.runtime_truth_search_requests
    ; runtime_truth_decisions
    ; source_echo = Some (Il.Print.string_of_rule rule)
    }
  in
  let helper_name =
    Helper.request
      (Context.helpers ctx)
      { Helper.kind = Helper.Runtime_enabledness request
      ; reason = Runtime_enabledness_helper.reason request
      ; origin
      }
  in
  Runtime_enabledness_helper.false_rewrite_condition ~helper_name request

let runtime_truth_false_support ctx truth_helper_name truth_request =
  Runtime_truth_decision_false_support.check
    ctx
    { Runtime_truth_decision_helper.truth_helper_name; truth_request }

let sole_truth_condition_matches premise_result truth_helper_name truth_request =
  let expected =
    Runtime_truth_search_helper.rewrite_condition
      ~helper_name:truth_helper_name
      truth_request
  in
  premise_result.Premise_result.rule_conditions = [ expected ]

let runtime_enabledness_unsupported ctx origin rule ~reason ~suggestion =
  unsupported
    ~ctx
    ~origin
    ~constructor:"RelD/ElsePr/enabledness/runtime-truth-false"
    ~source_echo:(Il.Print.string_of_rule rule)
    ~reason
    ~suggestion
    ()

let runtime_truth_false_unsupported
    ctx
    origin
    rule
    false_blockers
  =
  runtime_enabledness_unsupported
    ctx
    origin
    rule
    ~reason:
      ("enabledness complement depends on runtime predicate truth search whose false/no-hit refutation is not source-complete in the current helper slice: "
       ^ String.concat "; " false_blockers)
    ~suggestion:
      "Keep this otherwise complement Unsupported until the referenced runtime truth decision can materialize a total false rule"

let string_has_prefix ~prefix text =
  let prefix_len = String.length prefix in
  String.length text >= prefix_len
  && String.sub text 0 prefix_len = prefix

let subordinate_enabledness_blocker diagnostic =
  Diagnostics.is_fatal diagnostic
  && string_has_prefix
       ~prefix:"RelD/ElsePr/enabledness/"
       diagnostic.Diagnostics.constructor

let unique_texts texts =
  texts
  |> List.fold_left
       (fun texts text -> if List.mem text texts then texts else text :: texts)
       []
  |> List.rev

let summarized_enabledness_blockers diagnostics =
  diagnostics
  |> List.filter subordinate_enabledness_blocker
  |> List.map (fun diagnostic ->
    diagnostic.Diagnostics.constructor ^ ": " ^ diagnostic.reason)
  |> unique_texts

let without_subordinate_enabledness_blockers diagnostics =
  diagnostics
  |> List.filter (fun diagnostic ->
    not (subordinate_enabledness_blocker diagnostic))

let without_else_premises prems =
  prems
  |> List.filter (fun prem ->
    match prem.it with
    | ElsePr -> false
    | _ -> true)

type enabledness_info =
  { helper_name : string
  ; output : output
  ; complement_conditions : Maude_ir.rule_condition list
  }

type enabledness_result =
  | Not_applicable
  | Enabledness of enabledness_info

let helper_name relation_id rule_id index =
  "enabled-" ^ rule_label relation_id rule_id index

let translate_helper
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    input_sorts
    current_lhs_terms
    index
    rule =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
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
      Enabledness
        { helper_name = helper_name relation_id rule_id index
        ; output = { empty with diagnostics = hint_diags @ marker_diags }
        ; complement_conditions = []
        }
    else
      let input_typs = Relation_shape.component_typs shape.Relation_shape.inputs in
      let output_typs = Relation_shape.component_typs shape.Relation_shape.outputs in
      let expected_typs = input_typs @ output_typs in
      let components_opt, arity_diags =
        exp_components_match
          ctx
          origin
          "RelD/ElsePr/enabledness/arity"
          expected_typs
          exp
      in
      (match components_opt with
      | None ->
        Enabledness
          { helper_name = helper_name relation_id rule_id index
          ; output = { empty with diagnostics = arity_diags }
          ; complement_conditions = []
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
        let input_exps, _output_exps = split input_count [] components in
        let seed = helper_name relation_id rule_id index in
        let env, var_decls, bind_diags =
          translate_rule_binds ctx origin seed binds
        in
        let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
          lower_pattern_components ctx env origin input_exps
        in
        (match lhs_terms_opt with
        | Some lhs_terms
          when predecessor_matches_current current_lhs_terms lhs_terms ->
          let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
          let premise_result =
            Premise_translate.translate_premises
              ~allow_runtime_search:true
              ctx
              env
              ~bound_conditions:lhs_guards
              ~bound_terms:lhs_terms
              origin
              (without_else_premises prems)
          in
          let helper_name = helper_name relation_id rule_id index in
          let output diagnostics =
            { statements = var_decls
            ; diagnostics =
                hint_diags
                @ bind_diags @ arity_diags @ lhs_diags
                @ premise_result.diagnostics @ diagnostics
            }
          in
          let enabled ?(complement_conditions = []) diagnostics =
            Enabledness
              { helper_name
              ; output = output diagnostics
              ; complement_conditions
              }
          in
          if premise_result.rule_conditions = [] then
            (match
               direct_complement_conditions
                 current_lhs_terms
                 lhs_terms
                 premise_result.eq_conditions
             with
            | Some complement_conditions ->
              enabled ~complement_conditions []
            | None ->
              enabled
                [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"RelD/ElsePr/enabledness/non-total-bool"
                    ~source_echo:(Il.Print.string_of_rule rule)
                    ~reason:
                      "otherwise predecessor enabledness has only positive equational conditions, but the translator could not derive a source-level Bool complement from the predecessor head and premises"
                    ~suggestion:
                      "Implement a source-derived total enabledness decision or a documented direct complement for this premise shape before lowering the otherwise branch"
                    ()
                ])
          else if premise_result.runtime_truth_search_requests <> [] then
            (match
               ( premise_result.runtime_search_requests
               , premise_result.runtime_truth_search_requests )
             with
            | [], [ truth_request ] ->
              let truth_helper_name =
                truth_search_helper_name ctx origin truth_request
              in
              (match
                 runtime_truth_false_support ctx truth_helper_name truth_request
               with
              | Runtime_truth_decision_false_support.Supported
                when sole_truth_condition_matches
                       premise_result
                       truth_helper_name
                       truth_request ->
                let complement_condition =
                  runtime_enabledness_complement
                    ctx
                    origin
                    relation_id
                    rule_id
                    input_sorts
                    current_lhs_terms
                    lhs_terms
                    lhs_guards
                    premise_result
                    truth_helper_name
                    truth_request
                    rule
                in
                enabled ~complement_conditions:[ complement_condition ] []
              | Runtime_truth_decision_false_support.Supported ->
                enabled
                  [ runtime_enabledness_unsupported
                      ctx
                      origin
                      rule
                      ~reason:
                        "enabledness complement has a supported runtime truth false proof, but the predecessor rule condition is not exactly the corresponding truth-search rewrite condition"
                      ~suggestion:
                        "Keep this otherwise complement Unsupported until conjunction-level enabledness false rules can preserve all predecessor conditions"
                  ]
              | Runtime_truth_decision_false_support.Blocked false_blockers ->
                enabled
                  [ runtime_truth_false_unsupported
                      ctx
                      origin
                      rule
                      false_blockers
                  ]
              )
            | _ :: _, _ ->
              enabled
                [ runtime_enabledness_unsupported
                    ctx
                    origin
                    rule
                    ~reason:
                      "enabledness complement contains a runtime predicate search that binds new values; false/no-hit refutation for local-existential search is not source-complete yet"
                    ~suggestion:
                      "Keep this otherwise complement Unsupported until runtime search no-hit materialization has an all-or-nothing source proof"
                ]
            | [], _ ->
              enabled
                [ runtime_enabledness_unsupported
                    ctx
                    origin
                    rule
                    ~reason:
                      "enabledness complement has multiple runtime truth-search premises; the current helper only materializes false decisions for one source-complete truth predicate"
                    ~suggestion:
                      "Implement conjunction-level enabledness false rules before lowering this otherwise branch"
                ])
          else
            enabled
              [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"RelD/ElsePr/enabledness/rewrite-condition"
                  ~source_echo:(Il.Print.string_of_rule rule)
                  ~reason:
                    "enabledness helper for an otherwise predecessor contains rewrite conditions that are not runtime truth-search decisions"
                  ~suggestion:
                    "Keep this otherwise complement Unsupported until this rewrite-dependent premise shape has a source-complete enabledness decision helper"
                  ()
              ]
        | Some _ -> Not_applicable
        | None ->
          Enabledness
            { helper_name = helper_name relation_id rule_id index
            ; output =
                { statements = var_decls
                ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
                }
            ; complement_conditions = []
            }))

let complement
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    shape
    input_sorts
    origin
    current_lhs_terms
    previous_rules =
  let enabledness =
    previous_rules
    |> List.mapi (fun index rule ->
      translate_helper
        ctx
        rel_origin
        relation_id
        relation_kind
        relation_mixop
        shape
        input_sorts
        current_lhs_terms
        (index + 1)
        rule)
  in
  let applicable =
    enabledness
    |> List.filter_map (function
      | Not_applicable -> None
      | Enabledness result -> Some result)
  in
  match applicable with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ~ctx
            ~origin
            ~constructor:"RelD/RuleD/ElsePr/complement"
            ~reason:
              "source otherwise rule has no earlier rule with the same relation input skeleton, so the translator cannot derive a source enabledness complement"
            ~suggestion:
              "Keep this ElsePr Unsupported until rule grouping/preprocessing can prove the relevant predecessor rules"
            ()
        ]
    },
    []
  | _ ->
    let statements =
      applicable
      |> List.map (fun result -> result.output.statements)
      |> List.concat
    in
    let diagnostics =
      applicable
      |> List.map (fun result -> result.output.diagnostics)
      |> List.concat
    in
    let has_blocking = has_fatal diagnostics in
    let statements = if has_blocking then [] else statements in
    let complement_conditions =
      if has_blocking then
        []
      else
        applicable
        |> List.map (fun result -> result.complement_conditions)
        |> List.concat
    in
    if has_blocking then
      match
        Reld_enabledness_constructor_group.complement
          ctx
          ~rel_origin
          ~relation_id
          ~relation_kind
          ~relation_mixop
          shape
          ~input_sorts
          ~origin
          ~current_lhs_terms
          ~previous_rules
      with
      | Some (output, complement_conditions) -> output, complement_conditions
      | None ->
        let enabledness_blockers =
          summarized_enabledness_blockers diagnostics
        in
        let diagnostics =
          without_subordinate_enabledness_blockers diagnostics
        in
        let blocker_reason =
          match enabledness_blockers with
          | [] ->
            "at least one predecessor rule in this otherwise group needs enabledness conditions that are not safely expressible by the current source-derived helper slice"
          | blockers ->
            "at least one predecessor rule in this otherwise group needs enabledness conditions that are not safely expressible by the current source-derived helper slice; predecessor blockers: "
            ^ String.concat "; " blockers
        in
        { statements = []
        ; diagnostics =
            diagnostics
            @ [ unsupported
                ~ctx
                ~origin
                ~constructor:"RelD/RuleD/ElsePr/complement-unsupported"
                ~reason:blocker_reason
                ~suggestion:
                  "Leave this ElsePr Unsupported until the blocking predecessor premise shape has a documented source-complete helper"
                ()
            ]
        },
        []
    else
      { statements; diagnostics }, complement_conditions
