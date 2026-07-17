open Maude_ir
open Premise_result

let unsupported = Premise_diagnostic.unsupported
let source_echo_prem = Premise_diagnostic.source_echo_prem
let unsupported_prem = Premise_diagnostic.unsupported_prem

let relation_call rel_id inputs =
  App (Naming.relation_op rel_id, inputs)

let fresh_local_result_var names sort =
  Local_name.fresh_typed names Local_name.Result sort

let lower_input_values ctx env origin exps =
  let results = List.map (Expr_translate.lower_value ctx env origin) exps in
  let guards, diagnostics = Expr_result.append_result_metadata results in
  Expr_result.terms results, guards, diagnostics

let result_output_condition ctx bound pattern subject =
  let pattern_vars = Condition_closure.term_vars pattern in
  if
    Condition_closure.is_match_pattern
      ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
      pattern
  then MatchCond (pattern, subject)
  else if Condition_closure.vars_subset pattern_vars bound then
    EqCond (pattern, subject)
  else
    MatchCond (pattern, subject)

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

let case_args (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.TupE exps -> exps
  | _ -> [ exp ]

let add_projected_binding id term bindings =
  match List.assoc_opt id bindings with
  | None -> Ok ((id, term) :: bindings)
  | Some previous when previous = term -> Ok bindings
  | Some _ ->
    Error "one source output binder has two distinct constructor projections"

let exp_constructor (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.VarE _ -> "VarE"
  | Il.Ast.BoolE _ -> "BoolE"
  | Il.Ast.NumE _ -> "NumE"
  | Il.Ast.TextE _ -> "TextE"
  | Il.Ast.UnE _ -> "UnE"
  | Il.Ast.BinE _ -> "BinE"
  | Il.Ast.CmpE _ -> "CmpE"
  | Il.Ast.TupE _ -> "TupE"
  | Il.Ast.ProjE _ -> "ProjE"
  | Il.Ast.CaseE _ -> "CaseE"
  | Il.Ast.UncaseE _ -> "UncaseE"
  | Il.Ast.OptE _ -> "OptE"
  | Il.Ast.TheE _ -> "TheE"
  | Il.Ast.StrE _ -> "StrE"
  | Il.Ast.DotE _ -> "DotE"
  | Il.Ast.CompE _ -> "CompE"
  | Il.Ast.ListE _ -> "ListE"
  | Il.Ast.LiftE _ -> "LiftE"
  | Il.Ast.MemE _ -> "MemE"
  | Il.Ast.LenE _ -> "LenE"
  | Il.Ast.CatE _ -> "CatE"
  | Il.Ast.IdxE _ -> "IdxE"
  | Il.Ast.SliceE _ -> "SliceE"
  | Il.Ast.UpdE _ -> "UpdE"
  | Il.Ast.ExtE _ -> "ExtE"
  | Il.Ast.IfE _ -> "IfE"
  | Il.Ast.CallE _ -> "CallE"
  | Il.Ast.IterE _ -> "IterE"
  | Il.Ast.CvtE _ -> "CvtE"
  | Il.Ast.SubE _ -> "SubE"

let rec projected_pattern_bindings ctx subject bindings (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.VarE id when id.it = "_" -> Ok bindings
  | Il.Ast.VarE id -> add_projected_binding id.it subject bindings
  | Il.Ast.CaseE (mixop, arg_exp) ->
    let args = case_args arg_exp in
    (match
       Typcase_constructor.resolve_emitted
         ctx exp.note mixop ~arity:(List.length args)
     with
    | Typcase_constructor.Found resolution
      when
        List.length resolution.Typcase_constructor.projection_ops
        = List.length args ->
      List.fold_left2
        (fun bindings projection_op arg ->
          Result.bind bindings (fun bindings ->
            projected_pattern_bindings
              ctx (App (projection_op, [ subject ])) bindings arg))
        (Ok bindings) resolution.Typcase_constructor.projection_ops args
    | Typcase_constructor.Found _ ->
      Error
        "registered constructor projection arity does not match the source pattern"
    | Typcase_constructor.Missing ->
      Error "source output constructor has no exact emitted registry projection"
    | Typcase_constructor.Blocked reason -> Error reason
    | Typcase_constructor.Ambiguous _ ->
      Error "source output constructor has ambiguous emitted registry projections")
  | Il.Ast.IterE (body, (Il.Ast.Opt, [])) ->
    projected_pattern_bindings ctx subject bindings body
  | Il.Ast.IterE
      ({ it = Il.Ast.VarE body_id; _ },
       (Il.Ast.Opt, [ generator_id, source_exp ]))
    when body_id.it = generator_id.it ->
    projected_pattern_bindings ctx subject bindings source_exp
  | Il.Ast.IterE (body, (iter, generators)) ->
    let iter_name =
      match iter with
      | Il.Ast.Opt -> "Opt"
      | Il.Ast.List -> "List"
      | Il.Ast.List1 -> "List1"
      | Il.Ast.ListN _ -> "ListN"
    in
    Error
      (Printf.sprintf
         "source output pattern contains IterE(%s, generators=%d, body=%s) outside the exact optional constructor projection shape"
         iter_name (List.length generators) (exp_constructor body))
  | _ ->
    Error
      ("source output pattern contains " ^ exp_constructor exp
       ^ " outside a VarE/CaseE constructor tree with exact registry projections")

let projected_output_bindings
    ctx env ~bound_vars subject output_exp introduced =
  match projected_pattern_bindings ctx subject [] output_exp with
  | Error _ as error -> error
  | Ok projected ->
    projected
    |> List.fold_left
         (fun result (id, term) ->
           Result.bind result (fun bindings ->
             if Premise_state.source_id_is_bound env bound_vars id then
               Ok bindings
             else
             match List.assoc_opt id introduced, Expr_env.find env id with
             | Some binding, _ | None, Some binding ->
               Ok ((id, { binding with Expr_env.term }) :: bindings)
             | None, None ->
               Error
                 ("source output binder `" ^ id
                  ^ "` has no typed source binding for its exact constructor projection")))
         (Ok [])
    |> Result.map List.rev

let lower names ctx env ~bound_vars ~factor_head_domain origin prem rel_id exp
    (shape : Relation_shape.deterministic_shape) =
  let input_count = List.length shape.inputs in
  let expected_count = input_count + 1 in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    ( unsupported_prem ctx env ~bound_vars origin
        "Premise/RulePr/deterministic/arity" prem
        (Printf.sprintf
           "deterministic relation premise does not match the referenced RelD signature with %d input component(s) and one output component without flattening source tuple structure"
           input_count)
    , names )
  | Some components ->
    let input_exps, output_exps = split_prefix input_count components in
    match output_exps with
    | [ output_exp ] ->
      let input_terms_opt, input_guards, input_diags =
        lower_input_values ctx env origin input_exps
      in
      let output_pattern, names =
        Expr_translate.lower_pattern_with_bindings_named
          names ctx env origin output_exp
      in
      let output_sort_opt =
        Expr_translate.carrier_sort_of_typ shape.Relation_shape.output.typ
      in
      (match input_terms_opt, output_pattern.pattern_term, output_sort_opt with
      | Some input_terms, Some output_term, Some output_sort ->
        let binding_needed reason suggestion =
          ( { (empty_with_env ~bound_vars env) with
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
          , names )
        in
        (match
           Condition_admissibility.conditions_admissible_bound bound_vars input_guards
             ~constructor_op:
               (Condition_closure.source_constructor_certificate ctx)
         with
        | None ->
          binding_needed
            "deterministic relation input guards are not admissible before the relation result matching condition"
            "Bind the deterministic relation inputs through earlier source premises before calling the deterministic relation"
        | Some guard_bound ->
          let subject = relation_call rel_id input_terms in
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
            let result_var, names =
              fresh_local_result_var names output_sort
            in
            let result_condition = MatchCond (result_var, subject) in
            let condition =
              let bound_after_result =
                add_vars (Condition_closure.term_vars result_var) guard_bound
              in
              result_output_condition
                ctx
                bound_after_result
                output_term
                result_var
            in
            let conditions =
              input_guards @ [ result_condition; condition ]
              @ output_pattern.pattern_guards
            in
            if not factor_head_domain then
              let env_after =
                Premise_state.add_introduced_bindings
                  env output_pattern.introduced_bindings
              in
              ( { (empty_with_env
                   ~bound_vars:
                     (Condition_closure.conditions_bound_vars
                        ~constructor_op:
                          (Condition_closure.source_constructor_certificate ctx)
                        bound_vars conditions)
                   env_after) with
                eq_conditions = conditions
              ; diagnostics = input_diags @ output_pattern.pattern_diagnostics
                }
              , names )
            else match
               projected_output_bindings
                 ctx env ~bound_vars:guard_bound subject output_exp
                 output_pattern.introduced_bindings
             with
            | Ok projected_bindings ->
              let env_after =
                Premise_state.add_introduced_bindings env projected_bindings
              in
              ( { (empty_with_env
                   ~bound_vars:
                     (Condition_closure.conditions_bound_vars
                        ~constructor_op:
                          (Condition_closure.source_constructor_certificate ctx)
                        bound_vars conditions)
                   env_after) with
                eq_conditions = conditions
              ; enabledness_condition_blocks =
                  [ Head_domain_conditions conditions ]
              ; diagnostics = input_diags @ output_pattern.pattern_diagnostics
                }
              , names )
            | Error reason ->
              let env_after =
                Premise_state.add_introduced_bindings
                  env output_pattern.introduced_bindings
              in
              ( { (empty_with_env
                   ~bound_vars:
                     (Condition_closure.conditions_bound_vars
                        ~constructor_op:
                          (Condition_closure.source_constructor_certificate ctx)
                        bound_vars conditions)
                   env_after) with
                eq_conditions = conditions
              ; head_domain_failures =
                  [ Source_condition_certificate.failure
                      ~origin
                      ~constructor:
                        "Premise/RulePr/deterministic/head-domain-factoring"
                      ~reason
                      ~source_echo:(source_echo_prem prem)
                      ()
                  ]
              ; diagnostics = input_diags @ output_pattern.pattern_diagnostics
                }
              , names ))
      | _ ->
        ( { (empty_with_env ~bound_vars env) with
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
          }
        , names ))
    | _ ->
      ( unsupported_prem ctx env ~bound_vars origin
          "Premise/RulePr/deterministic/output" prem
          "deterministic relation premise requires exactly one output component in this helper-free slice"
      , names )
