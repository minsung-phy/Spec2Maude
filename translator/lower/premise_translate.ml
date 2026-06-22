open Il.Ast
open Maude_ir
open Util.Source

type result =
  { eq_conditions : eq_condition list
  ; rule_conditions : rule_condition list
  ; has_else : bool
  ; let_bound_ids : string list list
  ; env_after : Expr_translate.env
  ; bound_vars_after : string list
  ; diagnostics : Diagnostics.t list
  }

let normalize_vars vars =
  vars |> List.sort_uniq String.compare

let empty_with_env ?(bound_vars = []) env =
  { eq_conditions = []
  ; rule_conditions = []
  ; has_else = false
  ; let_bound_ids = []
  ; env_after = env
  ; bound_vars_after = normalize_vars bound_vars
  ; diagnostics = []
  }

let empty = empty_with_env Expr_translate.empty_env

let append left right =
  { eq_conditions = left.eq_conditions @ right.eq_conditions
  ; rule_conditions = left.rule_conditions @ right.rule_conditions
  ; has_else = left.has_else || right.has_else
  ; let_bound_ids = left.let_bound_ids @ right.let_bound_ids
  ; env_after = right.env_after
  ; bound_vars_after = right.bound_vars_after
  ; diagnostics = left.diagnostics @ right.diagnostics
  }

let unsupported ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let skipped ?suggestion ~ctx ~origin ~constructor ~reason ?source_echo () =
  Diagnostics.make
    ~category:Diagnostics.Skipped
    ~origin
    ~constructor
    ~enclosing:(Context.enclosing_path ctx)
    ~profile:(Context.profile_name ctx)
    ~reason
    ?suggestion
    ?source_echo
    ()

let source_echo_prem prem =
  Il.Print.string_of_prem prem

let source_echo_exp exp =
  Il.Print.string_of_exp exp

let origin_for_premise parent prem =
  Origin.with_child
    ~source_echo:(source_echo_prem prem)
    parent
    "premise"
    ~ast_constructor:"Premise"
    prem.at

let origin_for_if_conjunct parent segment exp =
  Origin.with_child
    ~source_echo:(Il.Print.string_of_exp exp)
    parent
    segment
    ~ast_constructor:"IfPr/BinE"
    exp.at

let unsupported_prem ctx env ~bound_vars origin constructor prem reason =
  { (empty_with_env ~bound_vars env) with
    diagnostics =
      [ unsupported
          ~ctx ~origin ~constructor
          ~source_echo:(source_echo_prem prem)
          ~reason
          ~suggestion:"Keep this premise as Unsupported until the generic lowering rule is implemented"
          ()
      ]
  }

let skipped_prem ctx env ~bound_vars origin constructor prem reason suggestion =
  { (empty_with_env ~bound_vars env) with
    diagnostics =
      [ skipped
          ~ctx ~origin ~constructor
          ~source_echo:(source_echo_prem prem)
          ~reason
          ~suggestion
          ()
      ]
  }

let add_vars vars bound =
  vars
  |> List.fold_left
       (fun bound var -> if List.mem var bound then bound else var :: bound)
       bound

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let condition_bound_vars bound = function
  | EqCond _ | MembershipCond _ | BoolCond _ -> bound
  | MatchCond (pattern, _subject) -> add_vars (Condition_closure.term_vars pattern) bound

let conditions_bound_vars initial_bound conditions =
  conditions |> List.fold_left condition_bound_vars initial_bound

let with_conditions env bound_vars conditions diagnostics =
  { (empty_with_env
       ~bound_vars:(conditions_bound_vars bound_vars conditions)
       env)
    with
    eq_conditions = conditions
  ; diagnostics
  }

let result_metadata
    (left : Expr_translate.result)
    (right : Expr_translate.result)
  =
  left.guards @ right.guards, left.diagnostics @ right.diagnostics

let result_has_fatal (result : Expr_translate.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let typ_is_iter = Type_shape.typ_is_iter

let flat_optional_element_typ typ =
  match typ.it with
  | IterT (element_typ, Opt) when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let source_free_var_ids exp =
  Il.Free.(free_exp exp).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let type_note_free_var_ids typ =
  Il.Free.(free_typ typ).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let source_and_note_free_var_ids exp =
  source_free_var_ids exp @ type_note_free_var_ids exp.note
  |> List.sort_uniq String.compare

let helper_local_stem origin source =
  let material =
    String.concat
      "\000"
      [ Origin.source_location origin; Origin.path origin; source ]
  in
  String.uppercase_ascii (String.sub (Digest.to_hex (Digest.string material)) 0 8)

let helper_local_prefix stem =
  "CAP" ^ stem ^ "X"

let app name args =
  App (name, args)

let is_opt term =
  app "isOpt" [ term ]

let pattern_result_has_fatal (result : Expr_translate.pattern_result) =
  List.exists Diagnostics.is_fatal result.pattern_diagnostics

let target_id ids id =
  match ids with
  | None -> true
  | Some ids -> List.exists (( = ) id) ids

let add_introduced_bindings ?ids env bindings =
  bindings
  |> List.fold_left
       (fun env (id, binding) ->
         if target_id ids id then
           Expr_translate.add_var env id binding
         else
           env)
       env

let try_match_condition
    ~bound
    (pattern_result : Expr_translate.pattern_result)
    (subject_result : Expr_translate.result)
  =
  match pattern_result.pattern_term, subject_result.term with
  | Some pattern, Some subject ->
    let guard_bound =
      conditions_bound_vars bound subject_result.guards
    in
    if
      (not (pattern_result_has_fatal pattern_result))
      && (not (result_has_fatal subject_result))
      && vars_subset (Condition_closure.term_vars subject) guard_bound
    then
      let conditions =
        subject_result.guards @ [ MatchCond (pattern, subject) ] @ pattern_result.pattern_guards
      in
      Some
        ( conditions
        , subject_result.diagnostics @ pattern_result.pattern_diagnostics )
    else
      None
  | _ -> None

let try_eq_condition left_result right_result =
  match
    (left_result : Expr_translate.result).term,
    (right_result : Expr_translate.result).term
  with
  | Some left, Some right ->
    if result_has_fatal left_result || result_has_fatal right_result then
      None
    else
      let guards, diagnostics = result_metadata left_result right_result in
      Some (guards @ [ EqCond (left, right) ], diagnostics)
  | _ -> None

let try_record_match_condition ~bound pattern_result subject_result =
  try_match_condition ~bound pattern_result subject_result

let lower_bool_premise ctx env ~bound_vars origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  match lowered.term with
  | Some term ->
    with_conditions env bound_vars (lowered.guards @ [ BoolCond term ]) lowered.diagnostics
  | None -> { (empty_with_env ~bound_vars env) with diagnostics = lowered.diagnostics }

let lower_eq_premise ctx env ~bound_vars origin (exp : exp) (left : exp) (right : exp) =
  let left_value = Expr_translate.lower_value ctx env origin left in
  let right_value = Expr_translate.lower_value ctx env origin right in
  let left_pattern = Expr_translate.lower_pattern_with_bindings ctx env origin left in
  let right_pattern = Expr_translate.lower_pattern_with_bindings ctx env origin right in
  let record_match =
    match left.it, right.it with
    | _, StrE _ ->
      try_record_match_condition ~bound:bound_vars right_pattern left_value
    | StrE _, _ ->
      try_record_match_condition ~bound:bound_vars left_pattern right_value
    | _ -> None
  in
  match record_match with
  | Some (conditions, diagnostics) ->
    let env_after =
      match left.it, right.it with
      | _, StrE _ -> add_introduced_bindings env right_pattern.introduced_bindings
      | StrE _, _ -> add_introduced_bindings env left_pattern.introduced_bindings
      | _ -> env
    in
    with_conditions env_after bound_vars conditions diagnostics
  | None ->
    (match try_match_condition ~bound:bound_vars left_pattern right_value with
    | Some (conditions, diagnostics) ->
      let env_after =
        add_introduced_bindings env left_pattern.introduced_bindings
      in
      with_conditions env_after bound_vars conditions diagnostics
    | None ->
      (match try_match_condition ~bound:bound_vars right_pattern left_value with
      | Some (conditions, diagnostics) ->
        let env_after =
          add_introduced_bindings env right_pattern.introduced_bindings
        in
        with_conditions env_after bound_vars conditions diagnostics
      | None ->
        (match try_eq_condition left_value right_value with
        | Some (conditions, diagnostics) ->
          with_conditions env bound_vars conditions diagnostics
        | None -> lower_bool_premise ctx env ~bound_vars origin exp)))

let binding_mem_left_unbound bound_vars (pattern_result : Expr_translate.pattern_result) =
  match pattern_result.pattern_term with
  | None -> false
  | Some term ->
    not (vars_subset (Condition_closure.term_vars term) bound_vars)

let lower_binding_mem_premise ctx env ~bound_vars origin exp left right =
  let left_pattern =
    Expr_translate.lower_pattern_with_bindings ctx env origin left
  in
  if not (binding_mem_left_unbound bound_vars left_pattern) then
    None
  else
    match flat_optional_element_typ right.note with
    | Some _ ->
      let right_result = Expr_translate.lower_sequence ctx env origin right in
      (match left_pattern.pattern_term, right_result.term with
      | Some left_term, Some right_term ->
        let singleton_pattern = app "seq" [ left_term ] in
        let conditions =
          right_result.guards @ [ MatchCond (singleton_pattern, right_term) ]
          @ left_pattern.pattern_guards
        in
        let env_after =
          add_introduced_bindings env left_pattern.introduced_bindings
        in
        Some
          (with_conditions
             env_after
             bound_vars
             conditions
             (right_result.diagnostics @ left_pattern.pattern_diagnostics))
      | _ ->
        Some
          { (empty_with_env ~bound_vars env) with
            diagnostics =
              right_result.diagnostics @ left_pattern.pattern_diagnostics
              @ [ unsupported
                    ~ctx
                    ~origin
                    ~constructor:"Premise/IfPr/MemE/binding"
                    ~source_echo:(source_echo_exp exp)
                    ~reason:
                      "binding membership over an optional source could not lower the left pattern or right optional source"
                    ~suggestion:
                      "Keep this premise Unsupported until both sides have source-shaped Maude terms"
                    ()
                ]
          })
    | None ->
      Some
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            left_pattern.pattern_diagnostics
            @ [ unsupported
                  ~ctx
                  ~origin
                  ~constructor:"Premise/IfPr/MemE/binding"
                  ~source_echo:(source_echo_exp exp)
                  ~reason:
                    ("binding membership requires an optional singleton source in this helper-free slice; source note is `"
                     ^ Il.Print.string_of_typ right.note
                     ^ "`")
                  ~suggestion:
                    "Use a source-preserving membership-search helper before lowering binding membership over general lists"
                  ()
              ]
        }

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
    lower_eq_premise ctx env ~bound_vars origin exp left right
  | MemE (left, right) ->
    (match lower_binding_mem_premise ctx env ~bound_vars origin exp left right with
    | Some result -> result
    | None -> lower_bool_premise ctx env ~bound_vars origin exp)
  | _ -> lower_bool_premise ctx env ~bound_vars origin exp

let relation_call rel_id inputs =
  App (Naming.relation_op rel_id, inputs)

let lower_value_components ctx env origin exps =
  let results =
    exps |> List.map (Expr_translate.lower_value ctx env origin)
  in
  let terms =
    results
    |> List.filter_map (fun (result : Expr_translate.result) -> result.term)
  in
  let guards =
    results
    |> List.map (fun (result : Expr_translate.result) -> result.guards)
    |> List.concat
  in
  let diagnostics =
    results
    |> List.map (fun (result : Expr_translate.result) -> result.diagnostics)
    |> List.concat
  in
  if List.length terms = List.length exps then
    Some terms, guards, diagnostics
  else
    None, guards, diagnostics

let lower_runtime_predicate_rule_premise
    ctx env ~bound_vars origin prem rel_id exp relation_shape =
  let expected_count = List.length relation_shape.Relation_shape.components in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-predicate/arity" prem
      (Printf.sprintf
         "runtime predicate relation premise does not match the referenced RelD signature component count %d without flattening source tuple structure"
         expected_count)
  | Some components ->
    let terms_opt, guards, diagnostics =
      lower_value_components ctx env origin components
    in
    match terms_opt with
    | Some terms ->
      (match Condition_closure.conditions_admissible_bound bound_vars guards with
      | None ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = guards
        ; diagnostics =
            diagnostics
            @ [ unsupported
                  ~ctx ~origin ~constructor:"Premise/RulePr/runtime-predicate/binding-needed"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "runtime predicate argument guards are not admissible in Maude condition order without a source-derived binding/search helper"
                  ~suggestion:
                    "Keep this RulePr Unsupported until a source-derived relation search/binding helper is implemented"
                  ()
              ]
        }
      | Some bound_after_guards ->
        let predicate_term = relation_call rel_id terms in
        let missing =
          Condition_closure.term_vars predicate_term
          |> List.filter (fun var -> not (List.mem var bound_after_guards))
          |> List.sort_uniq String.compare
        in
        if missing = [] then
          { (empty_with_env ~bound_vars:bound_after_guards env) with
            eq_conditions = guards @ [ BoolCond predicate_term ]
          ; diagnostics
          }
        else
          { (empty_with_env ~bound_vars env) with
            eq_conditions = guards
          ; diagnostics =
              diagnostics
              @ [ unsupported
                    ~ctx ~origin ~constructor:"Premise/RulePr/runtime-predicate/binding-needed"
                    ~source_echo:(source_echo_prem prem)
                    ~reason:
                      ("runtime predicate premise would need to bind variable(s), but Bool predicates cannot introduce values in Maude conditions: "
                       ^ String.concat ", " missing)
                    ~suggestion:
                      "Keep this RulePr Unsupported until a source-derived relation search/binding helper is implemented"
                    ()
                ]
          })
    | None ->
      { (empty_with_env ~bound_vars env) with
        eq_conditions = guards
      ; diagnostics =
          diagnostics
          @ [ unsupported
                ~ctx ~origin ~constructor:"Premise/RulePr/runtime-predicate/value"
                ~source_echo:(source_echo_prem prem)
                ~reason:
                  "runtime predicate premise arguments must lower as already-bound Maude values in this helper-free slice"
                ~suggestion:
                  "Keep this predicate premise Unsupported until a source-derived binding/complement helper is available"
                ()
            ]
      }

let output_condition_for_pattern bound pattern subject =
  let pattern_vars = Condition_closure.term_vars pattern in
  if vars_subset pattern_vars bound then
    EqCond (pattern, subject)
  else
    MatchCond (pattern, subject)

let lower_deterministic_rule_premise
    ctx env ~bound_vars origin prem rel_id exp
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
    let rec split n left right =
      if n = 0 then List.rev left, right
      else
        match right with
        | [] -> List.rev left, []
        | item :: rest -> split (n - 1) (item :: left) rest
    in
    let input_exps, output_exps = split input_count [] components in
    match output_exps with
    | [ output_exp ] ->
      let input_terms_opt, input_guards, input_diags =
        lower_value_components ctx env origin input_exps
      in
      let output_pattern =
        Expr_translate.lower_pattern_with_bindings ctx env origin output_exp
      in
      (match input_terms_opt, output_pattern.pattern_term with
      | Some input_terms, Some output_term ->
        let guard_bound =
          conditions_bound_vars bound_vars input_guards
        in
        let subject = relation_call rel_id input_terms in
        let condition =
          output_condition_for_pattern guard_bound output_term subject
        in
        let env_after =
          add_introduced_bindings env output_pattern.introduced_bindings
        in
        let conditions =
          input_guards @ [ condition ] @ output_pattern.pattern_guards
        in
        { (empty_with_env
             ~bound_vars:(conditions_bound_vars bound_vars conditions)
             env_after) with
          eq_conditions = conditions
        ; diagnostics = input_diags @ output_pattern.pattern_diagnostics
        }
      | _ ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = input_guards @ output_pattern.pattern_guards
        ; diagnostics =
            input_diags @ output_pattern.pattern_diagnostics
            @ [ unsupported
                  ~ctx ~origin ~constructor:"Premise/RulePr/deterministic/output"
                  ~source_echo:(source_echo_prem prem)
                  ~reason:
                    "deterministic relation premise requires all input expressions to lower as values and the output component to lower as a source-shaped pattern"
                  ~suggestion:
                    "Keep this premise Unsupported until a source-preserving inverse/pattern helper exists for the unsupported component"
                  ()
              ]
        })
    | _ ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/deterministic/output" prem
        "deterministic relation premise requires exactly one output component in this helper-free slice"

let lower_rule_premise ctx env ~bound_vars origin prem rel_id mixop =
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
        | RulePr (_, _, exp) ->
          lower_runtime_predicate_rule_premise
            ctx
            env
            ~bound_vars
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
      | RulePr (_, _, exp) ->
        lower_runtime_predicate_rule_premise
          ctx
          env
          ~bound_vars
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
      | RulePr (_, _, exp) ->
        lower_deterministic_rule_premise
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
    | Relation_shape.Execution _ ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/execution" prem
        ("execution relation premise cannot be emitted inside eq/ceq/cmb conditions; structural relation classification is "
         ^ relation_shape.Relation_shape.marker_text
         ^ ", so this requires RelD lowering plus rewrite-dependent DecD/crl helper support")
    | Relation_shape.Unknown reason ->
      unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/unknown" prem
        ("relation premise marker is not classified as validation, deterministic, or execution; structural relation classification is "
         ^ relation_shape.Relation_shape.marker_text
         ^ "; "
         ^ reason))

let lower_optional_if_iter_premise
    ctx env ~bound_vars origin prem body source_generator source_exp =
  let unsupported_optional_iter reason =
    unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/OptIf"
      ~source_echo:(source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the optional premise helper can preserve absent/present branches source-safely"
      ()
  in
  match flat_optional_element_typ source_exp.note with
  | None ->
    { (empty_with_env ~bound_vars env) with
      diagnostics =
        [ unsupported_optional_iter
            ("optional IfPr IterPr requires a flat optional source; source note is `"
             ^ Il.Print.string_of_typ source_exp.note
             ^ "`")
        ]
    }
  | Some source_element_typ ->
    (match Expr_translate.carrier_sort_of_typ source_element_typ with
    | None ->
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          [ unsupported_optional_iter
              "optional IfPr IterPr could not determine a Maude carrier for the optional element type"
          ]
      }
    | Some source_element_sort ->
      let source_result = Expr_translate.lower_sequence ctx env origin source_exp in
      (match source_result.term with
      | None ->
        { (empty_with_env ~bound_vars env) with
          eq_conditions = source_result.guards
        ; diagnostics = source_result.diagnostics
        }
      | Some source_term ->
        let source_bound =
          conditions_bound_vars bound_vars source_result.guards
        in
        if
          not
            (vars_subset
               (Condition_closure.term_vars source_term)
               source_bound)
        then
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_result.guards
          ; diagnostics =
              source_result.diagnostics
              @ [ unsupported_optional_iter
                    "optional premise source is not bound before the helper call; emitting a Bool helper condition would create a Maude used-before-bound variable"
                ]
          }
        else
          let stem = helper_local_stem origin (source_echo_prem prem) in
          let helper_head_var = "HEAD" ^ stem in
          let source_tail_var = "TAIL" ^ stem in
          let body_result_var = "BODY" ^ stem in
          let generator_binding =
            { Expr_translate.term = Var helper_head_var
            ; sort = source_element_sort
            ; typ = source_element_typ
            }
          in
          let preliminary_body_env =
            Expr_translate.add_var env source_generator.it generator_binding
          in
          let preliminary_body =
            Expr_translate.lower_bool_condition ctx preliminary_body_env origin body
          in
          (match preliminary_body.term with
          | None ->
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_result.guards
            ; diagnostics = source_result.diagnostics @ preliminary_body.diagnostics
            }
          | Some preliminary_body_term ->
            let required_vars =
              Condition_closure.external_vars_of_term_after_conditions
                [ helper_head_var; body_result_var ]
                preliminary_body_term
                preliminary_body.guards
            in
            let body_source_ids =
              source_and_note_free_var_ids body
              |> List.filter (fun id -> id <> source_generator.it)
              |> List.sort_uniq String.compare
            in
            let capture_candidates =
              body_source_ids
              |> List.fold_left
                   (fun captures source_id ->
                     match Expr_translate.find_var env source_id with
                     | Some ({ Expr_translate.term = Var var_name; _ } as binding)
                       when List.mem var_name required_vars ->
                       (source_id, var_name, binding) :: captures
                     | Some _ | None -> captures)
                   []
              |> List.rev
            in
            let captured_vars =
              capture_candidates
              |> List.map (fun (_source_id, var_name, _binding) -> var_name)
              |> List.sort_uniq String.compare
            in
            let missing_required_vars =
              required_vars
              |> List.filter (fun var_name -> not (List.mem var_name captured_vars))
            in
            let missing_diagnostics =
              missing_required_vars
              |> List.map (fun var_name ->
                unsupported_optional_iter
                  ("optional premise body has free Maude variable `"
                   ^ var_name
                   ^ "`, but no source variable maps to it as a plain capture"))
            in
            if missing_diagnostics <> [] then
              { (empty_with_env ~bound_vars env) with
                eq_conditions = source_result.guards
              ; diagnostics =
                  source_result.diagnostics @ preliminary_body.diagnostics
                  @ missing_diagnostics
              }
            else
              let capture_prefix = helper_local_prefix stem in
              let captures =
                capture_candidates
                |> List.mapi
                     (fun index (source_id, _var_name, (binding : Expr_translate.binding)) ->
                       { Helper.source_id = source_id
                       ; call_term = binding.term
                       ; formal_var = capture_prefix ^ string_of_int index
                       ; sort = binding.sort
                       ; typ = binding.typ
                       })
              in
              let helper_env =
                captures
                |> List.fold_left
                     (fun helper_env capture ->
                       Expr_translate.add_var helper_env capture.Helper.source_id
                         { Expr_translate.term = Var capture.Helper.formal_var
                         ; sort = capture.Helper.sort
                         ; typ = capture.Helper.typ
                         })
                     Expr_translate.empty_env
                |> fun helper_env ->
                Expr_translate.add_var helper_env source_generator.it generator_binding
              in
              let body_result =
                Expr_translate.lower_bool_condition ctx helper_env origin body
              in
              let body_vars =
                match body_result.term with
                | Some term ->
                  Condition_closure.external_vars_of_term_after_conditions
                    [ helper_head_var; body_result_var ]
                    term
                    body_result.guards
                | None -> []
              in
              let captures =
                captures
                |> List.filter (fun capture ->
                  List.mem capture.Helper.formal_var body_vars)
              in
              let allowed_vars =
                helper_head_var
                :: List.map (fun capture -> capture.Helper.formal_var) captures
              in
              let variable_diagnostics =
                if vars_subset body_vars allowed_vars then
                  []
                else
                  [ unsupported_optional_iter
                      "optional premise body references variables outside the helper head and captured closure variables"
                  ]
              in
              (match body_result.term, variable_diagnostics with
              | Some lowered_body, [] ->
                let helper_request =
                  { Helper.kind =
                      Helper.Iter_premise_opt_bool
                        { source_shape =
                            { prem_source = source_echo_prem prem
                            ; body_source = source_echo_exp body
                            ; source_source = source_echo_exp source_exp
                            ; source_typ_source = Il.Print.string_of_typ source_exp.note
                            }
                        ; generator_var = source_generator.it
                        ; helper_head_var
                        ; source_tail_var
                        ; body_result_var
                        ; source_element_sort
                        ; captures
                        ; lowered_body
                        ; body_eq_conditions = body_result.guards
                        }
                  ; reason = "optional IfPr IterPr Bool helper"
                  ; origin
                  }
                in
                let helper_name =
                  Helper.request (Context.helpers ctx) helper_request
                in
                let helper_call =
                  app helper_name
                    (source_term
                     :: List.map (fun capture -> capture.Helper.call_term) captures)
                in
                let caller_conditions =
                  source_result.guards
                  @ [ EqCond (is_opt source_term, Const "true")
                    ; BoolCond helper_call
                    ]
                in
                let caller_bound =
                  conditions_bound_vars bound_vars caller_conditions
                in
                let helper_missing_vars =
                  Condition_closure.term_vars helper_call
                  |> List.filter (fun var -> not (List.mem var caller_bound))
                  |> List.sort_uniq String.compare
                in
                if
                  helper_missing_vars = []
                then
                  with_conditions
                    env
                    bound_vars
                    caller_conditions
                    (source_result.diagnostics @ body_result.diagnostics)
                else
                  { (empty_with_env ~bound_vars env) with
                    eq_conditions = source_result.guards
                  ; diagnostics =
                      source_result.diagnostics @ body_result.diagnostics
                      @ [ unsupported_optional_iter
                            ("optional premise helper call contains variables that are not bound by earlier premise conditions: "
                             ^ String.concat ", " helper_missing_vars)
                        ]
                  }
              | _ ->
                { (empty_with_env ~bound_vars env) with
                  eq_conditions = source_result.guards
                ; diagnostics =
                    source_result.diagnostics @ body_result.diagnostics
                    @ variable_diagnostics
                }))))

let lower_iter_premise ctx env ~bound_vars origin prem body iter generators =
  match iter, generators, body.it with
  | Opt, [ source_generator, source_exp ], IfPr body_exp ->
    lower_optional_if_iter_premise
      ctx env ~bound_vars origin prem body_exp source_generator source_exp
  | _ ->
    unsupported_prem ctx env ~bound_vars origin "Premise/IterPr" prem
      "iterated premises require all/optional/ListN premise helpers; this slice supports only optional IfPr over one flat optional source"

let translate_premise ctx env ~bound_vars parent_origin prem =
  let origin = origin_for_premise parent_origin prem in
  let env = Expr_translate.with_condition_bound_vars env bound_vars in
  match prem.it with
  | IfPr exp -> lower_if_premise ctx env ~bound_vars origin exp
  | LetPr (lhs, rhs, ids) ->
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
  | RulePr (rel_id, mixop, _exp) ->
    lower_rule_premise ctx env ~bound_vars origin prem rel_id mixop
  | IterPr (body, (iter, generators)) ->
    lower_iter_premise ctx env ~bound_vars origin prem body iter generators
  | NegPr _ ->
    unsupported_prem ctx env ~bound_vars origin "Premise/NegPr" prem
      "negated premises require a total Bool/complement helper, which is outside this pure DecD slice"

let translate_premises ctx env ~bound_terms origin prems =
  let bound_vars =
    bound_terms
    |> List.map Condition_closure.term_vars
    |> List.concat
    |> normalize_vars
  in
  prems
  |> List.fold_left
       (fun acc prem ->
         let result =
           translate_premise
             ctx
             acc.env_after
             ~bound_vars:acc.bound_vars_after
             origin
             prem
         in
         append acc result)
       (empty_with_env ~bound_vars env)
