open Il.Ast
open Util.Source

module Request = Helper_request

open Reld_result
open Reld_rule_lowering
open Reld_enabledness_direct_complement

let rule_id_opt rule_id =
  if rule_id.it = "" || rule_id.it = "_" then None else Some rule_id.it

let truth_search_helper_name ctx origin truth_request =
  Helper.request
    (Context.helpers ctx)
    { Request.kind = Request.Runtime_predicate_truth_search truth_request
    ; reason = Runtime_truth_search_helper.reason truth_request
    ; origin
    }

let take_truth_worklist_helper ctx origin request =
  let helper_request =
    { Request.kind = Request.Runtime_predicate_truth_worklist request
    ; reason = Runtime_truth_worklist_helper.reason request
    ; origin
    }
  in
  match Helper.find (Context.helpers ctx) helper_request with
  | None -> None
  | Some name ->
    Helper.release (Context.helpers ctx) helper_request;
    Some name

let sole_worklist_condition_matches premise_result helper_name request =
  Premise_result.rule_conditions premise_result
  = [ Runtime_truth_worklist_helper.true_condition ~helper_name request ]

let truth_decision ctx origin truth_helper_name truth_request =
  let decision_request =
    { Runtime_truth_decision_helper.truth_helper_name
    ; truth_request
    }
  in
  let decision_helper_name =
    Helper.request
      (Context.helpers ctx)
      { Request.kind =
          Request.Runtime_predicate_truth_decision decision_request
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
    premise_result
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
    ; premise_eq_conditions = Premise_result.eq_conditions premise_result
    ; premise_rule_conditions = Premise_result.rule_conditions premise_result
    ; runtime_search_requests = Premise_result.runtime_search_requests premise_result
    ; runtime_truth_search_requests =
        Premise_result.runtime_truth_search_requests premise_result
    ; runtime_truth_decisions
    ; runtime_truth_worklist_decisions = []
    ; source_echo = Some (Il.Print.string_of_rule rule)
    }
  in
  let helper_name =
    Helper.request
      (Context.helpers ctx)
      { Request.kind = Request.Runtime_enabledness request
      ; reason = Runtime_enabledness_helper.reason request
      ; origin
      }
  in
  Runtime_enabledness_helper.false_rewrite_condition ~helper_name request

let runtime_worklist_enabledness_complement
    ctx origin relation_id rule_id input_sorts current_lhs_terms lhs_terms
    lhs_guards premise_result
    positive_helper_name positive_request total_helper_name total_request rule =
  let decision =
    { Runtime_truth_worklist_enabledness.positive_helper_name
    ; positive_request
    ; total_helper_name
    ; total_request
    }
  in
  let request =
    { Runtime_enabledness_helper.relation_id = relation_id.it
    ; rule_id = rule_id_opt rule_id
    ; call_terms = current_lhs_terms
    ; predecessor_terms = lhs_terms
    ; input_sorts
    ; lhs_conditions = lhs_guards
    ; premise_eq_conditions = Premise_result.eq_conditions premise_result
    ; premise_rule_conditions = Premise_result.rule_conditions premise_result
    ; runtime_search_requests = Premise_result.runtime_search_requests premise_result
    ; runtime_truth_search_requests =
        Premise_result.runtime_truth_search_requests premise_result
    ; runtime_truth_decisions = []
    ; runtime_truth_worklist_decisions = [ decision ]
    ; source_echo = Some (Il.Print.string_of_rule rule)
    }
  in
  let helper_name =
    Helper.request (Context.helpers ctx)
      { Request.kind = Request.Runtime_enabledness request
      ; reason = Runtime_enabledness_helper.reason request
      ; origin
      }
  in
  ( Runtime_enabledness_helper.false_rewrite_condition ~helper_name request
  , Runtime_enabledness_helper.surface ~helper_name ~origin request )

let runtime_truth_false_support ctx truth_helper_name truth_request =
  Runtime_truth_false_support.check
    ctx
    { Runtime_truth_decision_helper.truth_helper_name; truth_request }

let sole_truth_condition_matches premise_result truth_helper_name truth_request =
  let expected =
    Runtime_truth_search_helper.rewrite_condition
      ~helper_name:truth_helper_name
      truth_request
  in
  Premise_result.rule_conditions premise_result = [ expected ]

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
       ^ String.concat "; "
           (List.map
              Runtime_truth_false_support.blocker_reason
              false_blockers))
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
  ; complement_alternatives : Maude_ir.rule_condition list list
  }

type enabledness_result =
  | Not_applicable
  | Enabledness of enabledness_info

let helper_name relation_id rule_id index =
  Naming.helper_op
    ~role:"enabledness"
    ~owner:(rule_label relation_id rule_id index)

let direct_helper_op name = name
let direct_false_op = Naming.helper_companion ~role:"enabledness-direct-false"
let direct_helper_sort name =
  Maude_ir.sort ("RuntimeEnablednessDirect" ^ Naming.sort_token name ^ "Conf")

let origin_label_suffix predecessor current =
  ignore predecessor;
  ignore current;
  "source"

let direct_helper_surface name origin input_sorts =
  let generated node =
    Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node
  in
  let result_sort = direct_helper_sort name in
  let frozen = match input_sorts with
    | [] -> []
    | _ -> [ Maude_ir.Frozen (List.mapi (fun index _ -> index + 1) input_sorts) ]
  in
  [ generated (Maude_ir.sort_decl result_sort)
  ; generated
      (Maude_ir.op (direct_helper_op name)
         (List.map Maude_ir.sort_ref input_sorts) result_sort ~attrs:frozen)
  ; generated (Maude_ir.op (direct_false_op name) [] result_sort ~attrs:[ Maude_ir.Ctor ])
  ]

let materialize_direct_complement
    ctx origin current_origin name input_sorts current_lhs_terms alternatives =
  let generated node =
    Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node
  in
  let lhs = Maude_ir.App (direct_helper_op name, current_lhs_terms) in
  let rhs = Maude_ir.Const (direct_false_op name) in
  let rules = alternatives |> List.mapi (fun index conditions ->
    let conditions =
      Condition_closure.normalize_rule_conditions
        ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
        [ lhs ] conditions
      |> dedup_rule_conditions
    in
    let diagnostics =
      Condition_closure.crl_admissibility_diagnostics ctx origin lhs rhs conditions
    in
    generated
      (Maude_ir.crl
         ~label:
           (Maude_ir.sanitize_label
              (name ^ "-" ^ origin_label_suffix origin current_origin ^ "-false-"
               ^ string_of_int (index + 1)))
         lhs rhs conditions),
    diagnostics)
  in
  let statements = direct_helper_surface name origin input_sorts @ List.map fst rules in
  let diagnostics = List.concat_map snd rules in
  let diagnostics = diagnostics @ List.concat_map (generated_statement_diagnostics ctx) statements in
  statements, diagnostics,
  Maude_ir.RewriteCond (lhs, rhs)

let translate_helper
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    input_sorts
    current_origin
    current_lhs_terms
    current_lhs_guards
    index
    rule =
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
      Enabledness
        { helper_name = helper_name relation_id rule_id index
        ; output = { empty with diagnostics = hint_diags @ marker_diags }
        ; complement_alternatives = []
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
          ; complement_alternatives = []
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
        let env, var_decls, bind_diags, names =
          translate_rule_binds ctx origin names binds
        in
        let (lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags), names =
          lower_pattern_components_named names ctx env origin input_exps
        in
        (match lhs_terms_opt with
        | Some lhs_terms
          when predecessor_matches_current current_lhs_terms lhs_terms ->
          let env = add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings in
          let premise_translation, _names =
            Premise_translate.translate_premises_named
              names
              ~allow_runtime_search:true
              ~factor_head_domains:true
              ctx
              env
              ~bound_conditions:lhs_guards
              ~bound_terms:lhs_terms
              origin
              (without_else_premises prems)
          in
          let helper_name = helper_name relation_id rule_id index in
          (match premise_translation with
          | Premise_result.Blocked diagnostics
          | Deferred (_, diagnostics) ->
            Enabledness
              { helper_name
              ; output =
                  { statements = var_decls
                  ; diagnostics =
                      hint_diags @ bind_diags @ arity_diags @ lhs_diags
                      @ diagnostics
                  }
              ; complement_alternatives = []
              }
          | Complete premise_result ->
          let output ?(statements = []) diagnostics =
            { statements = var_decls @ statements
            ; diagnostics =
                hint_diags
                @ bind_diags @ arity_diags @ lhs_diags
                @ Premise_result.diagnostics premise_result @ diagnostics
            }
          in
          let enabled
              ?(statements = []) ?(complement_alternatives = []) diagnostics =
            Enabledness
              { helper_name
              ; output = output ~statements diagnostics
              ; complement_alternatives
              }
          in
          if Premise_result.rule_conditions premise_result = [] then
            (match
               direct_complement_alternatives
                 (Context.constructors ctx)
                 ~origin
                 ~helper_name
                 ~current_head_conditions:current_lhs_guards
                 ~predecessor_head_conditions:lhs_guards
                 ~condition_blocks:
                   (Premise_result.enabledness_condition_blocks premise_result
                    |> List.map (function
                      | Premise_result.Source_conditions conditions ->
                        Source_conditions conditions
                      | Premise_result.Head_domain_conditions conditions ->
                        Head_domain_conditions conditions))
                 ~head_domain_failures:
                   (Premise_result.head_domain_failures premise_result
                    |> List.map (fun failure ->
                      failure.Source_condition_certificate.constructor
                      ^ " at " ^ Origin.summary failure.origin ^ ": "
                      ^ failure.reason))
                 ~condition_certificates:
                   (Premise_result.source_condition_certificates premise_result)
                 ~condition_failures:
                   (Premise_result.source_condition_failures premise_result)
                 current_lhs_terms
                 lhs_terms
                 (Premise_result.eq_conditions premise_result)
             with
            | Complete { alternatives = []; statements = _ } ->
              enabled ~complement_alternatives:[] []
            | Complete complete ->
              let statements, diagnostics, complement =
                materialize_direct_complement
                  ctx origin current_origin helper_name input_sorts current_lhs_terms
                  complete.alternatives
              in
              let support_diagnostics =
                List.concat_map
                  (generated_statement_diagnostics ctx)
                  complete.statements
              in
              Enabledness
                { helper_name
                ; output =
                    { statements =
                        var_decls @ complete.statements @ statements
                    ; diagnostics =
                        hint_diags @ bind_diags @ arity_diags @ lhs_diags
                        @ Premise_result.diagnostics premise_result
                        @ support_diagnostics
                        @ diagnostics
                    }
                ; complement_alternatives = [ [ complement ] ]
                }
            | Blocked reasons ->
              enabled
                [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"RelD/ElsePr/enabledness/non-total-bool"
                    ~source_echo:(Il.Print.string_of_rule rule)
                    ~reason:
                      ("otherwise predecessor enabledness is not source-completely complementable: "
                       ^ String.concat "; " reasons)
                    ~suggestion:
                      "Implement a source-derived total enabledness decision or a documented direct complement for this premise shape before lowering the otherwise branch"
                    ()
                ])
          else if
            Premise_result.runtime_truth_worklist_requests premise_result <> []
          then
            (match
               ( Premise_result.runtime_search_requests premise_result
               , Premise_result.runtime_truth_search_requests premise_result
               , Premise_result.runtime_truth_worklist_requests premise_result )
             with
            | [], [], [ request ] ->
              (match take_truth_worklist_helper ctx origin request with
              | Some worklist_name
                when sole_worklist_condition_matches premise_result worklist_name request ->
                (match
                   Runtime_truth_worklist_enabledness.total_request_for_source_binders
                     ~current_terms:current_lhs_terms
                     ~predecessor_terms:lhs_terms
                     request
                 with
                | Runtime_truth_worklist_enabledness.Ready _
                  when Premise_result.eq_conditions premise_result <> [] ->
                  enabled
                    [ runtime_enabledness_unsupported ctx origin rule
                        ~reason:
                          "the predecessor worklist is preceded/followed by equational premise conditions; a false decision needs source-ordered first-failure alternatives for each equation, not only the final worklist refuter"
                        ~suggestion:
                          "Preserve one ordered mixed condition sequence and certify every equation-failure branch before lowering this otherwise predecessor"
                    ]
                | Runtime_truth_worklist_enabledness.Ready total_request ->
                  let total_helper_name =
                    Helper.request (Context.helpers ctx)
                      { Request.kind =
                          Request.Runtime_predicate_truth_worklist total_request
                      ; reason = Runtime_truth_worklist_helper.reason total_request
                      ; origin
                      }
                  in
                  let complement_condition, surface =
                    runtime_worklist_enabledness_complement
                      ctx origin relation_id rule_id input_sorts current_lhs_terms
                      lhs_terms lhs_guards premise_result worklist_name request
                      total_helper_name total_request rule
                  in
                  enabled ~statements:surface
                    ~complement_alternatives:[[ complement_condition ]] []
                | Runtime_truth_worklist_enabledness.Incomplete_decision relations ->
                  enabled
                    [ runtime_enabledness_unsupported ctx origin rule
                        ~reason:
                          ("runtime truth worklist has finite positive successors, but transitive relation(s) lack exhaustive direct-successor coverage: "
                           ^ String.concat ", " relations)
                        ~suggestion:
                          "Classify every non-transitive source RuleD as an exhaustive finite successor producer before emitting the false decision"
                    ]
                | Runtime_truth_worklist_enabledness.Head_mismatch ->
                  enabled
                    [ runtime_enabledness_unsupported ctx origin rule
                        ~reason:
                          "runtime truth worklist inputs cannot be specialized from the predecessor pattern onto the current execution lhs"
                        ~suggestion:
                          "Preserve an explicit admissible predecessor-head match before invoking the false certificate"
                    ])
              | Some _ ->
                enabled
                  [ runtime_enabledness_unsupported ctx origin rule
                      ~reason:
                        "runtime truth worklist is total, but the predecessor contains additional rewrite conditions outside that atomic decision"
                      ~suggestion:
                        "Preserve conjunction-level false certificates before combining this worklist with other rewrite premises"
                  ]
              | None ->
                enabled
                  [ runtime_enabledness_unsupported ctx origin rule
                      ~reason:
                        "enabledness analysis lost the registered positive runtime truth helper before capture specialization"
                      ~suggestion:
                        "Keep helper registration and enabledness premise analysis in one scoped request lifecycle"
                  ])
            | _ ->
              enabled
                [ runtime_enabledness_unsupported ctx origin rule
                    ~reason:
                      "enabledness complement requires exactly one atomic runtime truth worklist decision"
                    ~suggestion:
                      "Materialize a conjunction-level exhaustive certificate before lowering this otherwise rule"
                ])
          else if
            Premise_result.runtime_truth_search_requests premise_result <> []
          then
            (match
               ( Premise_result.runtime_search_requests premise_result
               , Premise_result.runtime_truth_search_requests premise_result )
             with
            | [], [ truth_request ] ->
              let truth_helper_name =
                truth_search_helper_name ctx origin truth_request
              in
              (match
                 runtime_truth_false_support ctx truth_helper_name truth_request
               with
              | Runtime_truth_false_support.Supported
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
                enabled ~complement_alternatives:[[ complement_condition ]] []
              | Runtime_truth_false_support.Supported ->
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
              | Runtime_truth_false_support.Blocked false_blockers ->
                enabled
                  (List.map
                     (Runtime_truth_false_support.diagnostic ctx)
                     false_blockers
                   @ [ runtime_truth_false_unsupported
                      ctx
                      origin
                      rule
                      false_blockers
                     ])
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
              ])
        | Some _ -> Not_applicable
        | None ->
          Enabledness
            { helper_name = helper_name relation_id rule_id index
            ; output =
                { statements = var_decls
                ; diagnostics = hint_diags @ bind_diags @ arity_diags @ lhs_diags
                }
            ; complement_alternatives = []
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
    current_lhs_guards
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
        origin
        current_lhs_terms
        current_lhs_guards
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
    let combine alternatives choices =
      alternatives
      |> List.concat_map (fun prefix ->
        choices |> List.map (fun choice -> prefix @ choice))
    in
    let complement_alternatives =
      if has_blocking then
        []
      else
        applicable
        |> List.fold_left
             (fun alternatives result ->
               combine alternatives result.complement_alternatives)
             [ [] ]
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
      | Reld_enabledness_constructor_group.Materialized
          (output, complement_conditions) -> output, [ complement_conditions ]
      | Blocked group_diagnostics ->
        { statements = []
        ; diagnostics =
            without_subordinate_enabledness_blockers diagnostics
            @ group_diagnostics
        },
        []
      | Not_applicable ->
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
      { statements; diagnostics }, complement_alternatives
