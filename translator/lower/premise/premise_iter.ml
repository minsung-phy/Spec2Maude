open Il.Ast
open Maude_ir
open Util.Source

module Request = Helper_request

open Helper_capture
open Premise_result

type lower_body =
  Local_name.t ->
  Context.t ->
  Expr_env.t ->
  bound_vars:string list ->
  Origin.t ->
  Il.Ast.prem ->
  Premise_result.result * Local_name.t

let app name args = App (name, args)

let diagnostics_have_fatal diagnostics =
  List.exists Diagnostics.is_fatal diagnostics

let return names result = result, names

let count_is_total ctx env ~bound_vars origin exp =
  let bound =
    Il.Free.(free_exp exp).varid
    |> Il.Free.Set.elements
    |> List.filter (Premise_state.source_id_is_bound env bound_vars)
  in
  Runtime_truth_totality.source_total ctx ~bound origin exp

let rec lower_list_iter_premise
    names lower_body
    ctx env ~bound_vars origin prem body iter source_generator source_exp =
  let unsupported_list_iter reason =
    Premise_diagnostic.unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/List"
      ~source_echo:(Premise_diagnostic.source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the repeated premise can be lowered as source-shaped structural recursion without search or rewrite conditions"
      ()
  in
  match Premise_shape.flat_list_element_typ source_exp.note with
  | None ->
    return names
      { (empty_with_env ~bound_vars env) with
        diagnostics =
          [ unsupported_list_iter
              ("list IterPr requires one flat list source; source note is `"
               ^ Il.Print.string_of_typ source_exp.note
               ^ "`")
          ]
      }
  | Some source_element_typ ->
    (match Expr_translate.carrier_sort_of_typ source_element_typ with
    | None ->
      return names
        { (empty_with_env ~bound_vars env) with
          diagnostics =
            [ unsupported_list_iter
                "list IterPr could not determine a Maude carrier for the source element type"
            ]
        }
    | Some source_element_sort ->
      let source_result = Expr_translate.lower_sequence ctx env origin source_exp in
      (match source_result.term with
      | None ->
        return names
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_result.guards
          ; diagnostics = source_result.diagnostics
          }
      | Some source_term ->
        let source_bound =
          Condition_closure.conditions_bound_vars bound_vars source_result.guards
        in
        if
          not
            (Condition_closure.vars_subset
               (Condition_closure.term_vars source_term)
               source_bound)
        then
          return names
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_result.guards
            ; diagnostics =
                source_result.diagnostics
                @ [ unsupported_list_iter
                      "list IterPr source is not bound before the helper call; emitting a Bool helper condition would create a Maude used-before-bound variable"
                  ]
            }
        else
          let body_source_ids =
            Source_free_vars.prem_ids body
            |> List.filter (fun id -> id <> source_generator.it)
            |> List.sort_uniq String.compare
          in
          let helper_names =
            Local_name.reserve_sources
              Local_name.empty (source_generator.it :: body_source_ids)
          in
          let helper_head_var =
            Local_name.source_qualified_name
              helper_names source_generator.it (sort_ref source_element_sort)
          in
          let source_tail_var, helper_names =
            Local_name.fresh_qualified_name
              helper_names Local_name.Tail (sort_ref (sort "SpectecTerminals"))
          in
          let generator_binding =
            { Expr_env.term = Var helper_head_var
            ; sort = source_element_sort
            ; typ = source_element_typ
            }
          in
          let captures =
            body_source_ids
            |> capture_candidates env
            |> make_captures helper_names
          in
          let helper_env =
            Expr_env.add
              (capture_env captures)
              source_generator.it
              generator_binding
          in
          let helper_bound =
            helper_head_var :: capture_vars captures
          in
          let body_result, names =
            lower_body names ctx helper_env ~bound_vars:helper_bound origin body
          in
          let body_input_bound = helper_bound in
          let body_used_vars =
            let eq_bound =
              Condition_closure.conditions_bound_vars
                [ helper_head_var ]
                body_result.eq_conditions
            in
            Condition_closure.external_vars_of_conditions
              [ helper_head_var ] body_result.eq_conditions
            @ Condition_closure.external_vars_of_rule_conditions
                eq_bound body_result.rule_conditions
            |> List.sort_uniq String.compare
          in
          let captures =
            captures |> filter_used_captures body_used_vars
          in
          let helper_bound =
            helper_head_var :: capture_vars captures
          in
          let body_external =
            let eq_external =
              Condition_closure.external_vars_of_conditions
                helper_bound body_result.eq_conditions
            in
            let eq_bound =
              Condition_closure.conditions_bound_vars
                helper_bound body_result.eq_conditions
            in
            eq_external
            @ Condition_closure.external_vars_of_rule_conditions
                eq_bound body_result.rule_conditions
            |> List.sort_uniq String.compare
          in
          let introduced_vars =
            body_result.bound_vars_after
            |> List.filter (fun var -> not (List.mem var body_input_bound))
            |> List.sort_uniq String.compare
          in
          let structural_diagnostics =
            body_external
            |> List.map (fun var_name ->
              unsupported_list_iter
                ("list IterPr helper body would need external variable `"
                 ^ var_name
                 ^ "` after captures; this would not be source-local structural recursion"))
          in
          let helper_rule_conditions =
            List.map (fun condition -> EqCondition condition) body_result.eq_conditions
            @ body_result.rule_conditions
            |> Condition_closure.normalize_rule_conditions
                 ~constructor_op:
                   (Condition_closure.source_constructor_certificate ctx)
                 (Var helper_head_var
                  :: List.map (fun capture -> capture.Request.call_term) captures)
          in
          let structural_diagnostics =
            match
              Condition_admissibility.rule_conditions_admissible_bound
                ~constructor_op:
                  (Condition_closure.source_constructor_certificate ctx)
                helper_bound helper_rule_conditions
            with
            | Some _ -> structural_diagnostics
            | None ->
              unsupported_list_iter
                "list IterPr body conditions are not Maude-admissible from the source element and captured variables"
              :: structural_diagnostics
          in
          let structural_diagnostics =
            if body_result.has_else then
              unsupported_list_iter
                "list IterPr body contains ElsePr; otherwise/complement semantics need a separate source-derived helper"
              :: structural_diagnostics
            else
              structural_diagnostics
          in
          let structural_diagnostics =
            if body_result.let_bound_ids <> [] || introduced_vars <> [] then
              unsupported_list_iter
                ("list IterPr body introduces variable(s) that would escape the repeated check: "
                 ^ String.concat ", " introduced_vars)
              :: structural_diagnostics
            else
              structural_diagnostics
          in
          if diagnostics_have_fatal body_result.diagnostics
             || structural_diagnostics <> []
          then
            return names
              { (empty_with_env ~bound_vars env) with
                eq_conditions = source_result.guards
              ; diagnostics =
                  source_result.diagnostics @ body_result.diagnostics
                  @ structural_diagnostics
              }
          else
            let source_shape =
              { Request.prem_source = Premise_diagnostic.source_echo_prem prem
              ; body_source = Premise_diagnostic.source_echo_prem body
              ; source_source = Premise_diagnostic.source_echo_exp source_exp
              ; source_typ_source = Il.Print.string_of_typ source_exp.note
              ; iter_source = Il.Print.string_of_iter iter
              }
            in
            let iter_guards, count_diagnostics =
              match iter with
              | List -> Some [], []
              | List1 ->
                Some [ BoolCond (app "_=/=_" [ source_term; Const "eps" ]) ], []
              | ListN (n_exp, None) ->
                let n_result = Expr_translate.lower_value ctx env origin n_exp in
                (match n_result.term with
                | Some n_term
                  when not (diagnostics_have_fatal n_result.diagnostics)
                       && count_is_total ctx env ~bound_vars origin n_exp ->
                  Some
                    (n_result.guards
                     @ [ EqCond (app "len" [ source_term ], n_term) ]),
                  n_result.diagnostics
                | Some _ | None ->
                  None,
                  n_result.diagnostics
                  @ [ unsupported_list_iter
                        "ListN count did not lower to an admissible Maude term; exact source length cannot be enforced"
                    ])
              | ListN (_, Some _) | Opt -> None, []
            in
            let caller_eq_conditions =
              Option.map (fun guards -> source_result.guards @ guards) iter_guards
            in
            let helper_args =
              source_term
              :: List.map (fun capture -> capture.Request.call_term) captures
            in
            let helper_missing_vars =
              match caller_eq_conditions with
              | None -> []
              | Some conditions ->
                Condition_closure.external_vars_of_conditions bound_vars conditions
                @ (helper_args
                   |> List.concat_map Condition_closure.term_vars
                   |> List.filter (fun var ->
                     not
                       (List.mem var
                          (Condition_closure.conditions_bound_vars
                             bound_vars conditions))))
                |> List.sort_uniq String.compare
            in
            let blocked () =
              return names
                { (empty_with_env ~bound_vars env) with
                  eq_conditions = source_result.guards
                ; diagnostics =
                    source_result.diagnostics @ body_result.diagnostics
                    @ count_diagnostics
                    @ (match helper_missing_vars with
                      | [] -> []
                      | _ ->
                        [ unsupported_list_iter
                            ("list IterPr helper call contains variables that are not bound by earlier premise conditions: "
                             ^ String.concat ", " helper_missing_vars)
                        ])
                }
            in
            if diagnostics_have_fatal count_diagnostics
               || helper_missing_vars <> []
            then blocked ()
            else match caller_eq_conditions with
            | None -> blocked ()
            | Some caller_eq_conditions ->
            let helper_request =
              if body_result.rule_conditions = [] then
                { Request.kind =
                    Request.Iter_premise_list_bool
                      { source_shape
                      ; generator_var = source_generator.it
                      ; helper_head_var
                      ; source_tail_var
                      ; source_element_sort
                      ; captures
                      ; body_eq_conditions = body_result.eq_conditions
                      }
                ; reason = "list IterPr structural Bool helper"
                ; origin
                }
              else
                { Request.kind =
                    Request.Iter_premise_list_rule
                      { source_shape
                      ; generator_var = source_generator.it
                      ; helper_head_var
                      ; source_tail_var
                      ; source_element_sort
                      ; captures
                      ; body_conditions = helper_rule_conditions
                      }
                ; reason = "list IterPr structural rewrite helper"
                ; origin
                }
            in
            let helper_name =
              Helper.request (Context.helpers ctx) helper_request
            in
            let helper_call =
              app helper_name helper_args
            in
              let caller_eq_conditions, caller_rule_conditions =
                if body_result.rule_conditions = [] then
                  caller_eq_conditions @ [ BoolCond helper_call ], []
                else
                  caller_eq_conditions,
                  [ RewriteCond
                      ( helper_call
                      , Const (Naming.helper_companion ~role:"premise-all-ok" helper_name) )
                  ]
              in
              let bound_vars_after =
                Condition_closure.conditions_bound_vars
                  bound_vars caller_eq_conditions
              in
              return names
                { (empty_with_env ~bound_vars:bound_vars_after env) with
                  eq_conditions = caller_eq_conditions
                ; rule_conditions = caller_rule_conditions
                ; runtime_search_requests = body_result.runtime_search_requests
                ; runtime_truth_search_requests =
                    body_result.runtime_truth_search_requests
                ; runtime_truth_worklist_requests =
                    body_result.runtime_truth_worklist_requests
                ; diagnostics =
                    source_result.diagnostics @ body_result.diagnostics
                    @ count_diagnostics
                }
            ))

and lower_zip_iter_premise names lower_body ctx env ~bound_vars origin prem body iter generators =
  let unsupported_zip_iter reason =
    Premise_diagnostic.unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/Zip"
      ~source_echo:(Premise_diagnostic.source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the lockstep repeated premise can be lowered as source-shaped structural recursion without search or rewrite conditions"
      ()
  in
  let generator_ids = generators |> List.map (fun (id, _exp) -> id.it) in
  let body_source_ids =
    Source_free_vars.prem_ids body
    |> List.filter (fun id -> not (List.mem id generator_ids))
    |> List.sort_uniq String.compare
  in
  let helper_names =
    Local_name.reserve_sources
      Local_name.empty (generator_ids @ body_source_ids)
  in
  let lower_source helper_names (source_generator, source_exp) =
    match Premise_shape.zip_source_descriptor source_exp.note with
    | None ->
      Error
        [ unsupported_zip_iter
            ("zip IterPr requires every source to be a flat list or boundary-preserving nested T** list; source `"
             ^ source_generator.it
             ^ "` has note `"
             ^ Il.Print.string_of_typ source_exp.note
             ^ "`")
        ]
    | Some (source_item_shape, source_element_typ) ->
      (match Expr_translate.carrier_sort_of_typ source_element_typ with
      | None ->
        Error
          [ unsupported_zip_iter
              ("zip IterPr could not determine a Maude carrier for source `"
               ^ source_generator.it
               ^ "`")
          ]
      | Some source_element_sort ->
        let source_result =
          Expr_translate.lower_sequence ctx env origin source_exp
        in
        (match source_result.term with
        | None -> Error source_result.diagnostics
        | Some source_term ->
          let source_tail_var, helper_names =
            Local_name.fresh_qualified_name
              helper_names Local_name.Tail
              (sort_ref (sort "SpectecTerminals"))
          in
          Ok
            ( ( source_generator
              , source_exp
              , source_result
              , source_term
              , source_item_shape
              , source_element_typ
              , source_element_sort
              , Local_name.source_qualified_name
                  helper_names source_generator.it
                  (sort_ref source_element_sort)
              , source_tail_var )
            , helper_names )))
  in
  let rec collect helper_names acc diagnostics = function
    | [] ->
      if diagnostics = [] then Ok (List.rev acc, helper_names) else Error diagnostics
    | generator :: generators ->
      (match lower_source helper_names generator with
      | Ok (source, helper_names) ->
        collect helper_names (source :: acc) diagnostics generators
      | Error source_diagnostics ->
        collect helper_names acc (diagnostics @ source_diagnostics) generators)
  in
  match collect helper_names [] [] generators with
  | Error diagnostics ->
    return names { (empty_with_env ~bound_vars env) with diagnostics }
  | Ok (sources, helper_names) ->
    let source_guards =
      sources
      |> List.concat_map (fun (_, _, source_result, _, _, _, _, _, _) ->
        source_result.Expr_result.guards)
    in
    let source_diagnostics =
      sources
      |> List.concat_map (fun (_, _, source_result, _, _, _, _, _, _) ->
        source_result.Expr_result.diagnostics)
    in
    let source_bound =
      Condition_closure.conditions_bound_vars
        ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
        bound_vars source_guards
    in
    let unbound_source_vars =
      sources
      |> List.concat_map (fun (_id, _exp, _source_result, source_term, _, _, _, _, _) ->
        Condition_closure.term_vars source_term)
      |> List.filter (fun var -> not (List.mem var source_bound))
      |> List.sort_uniq String.compare
    in
    if unbound_source_vars <> [] then
      return names
        { (empty_with_env ~bound_vars env) with
          eq_conditions = source_guards
        ; diagnostics =
            source_diagnostics
            @ [ unsupported_zip_iter
                  ("zip IterPr source term uses variable(s) before binding: "
                   ^ String.concat ", " unbound_source_vars)
              ]
        }
    else
      let generator_bindings =
        sources
        |> List.map
             (fun (source_generator, _source_exp, _source_result, _source_term,
                   _source_item_shape, source_element_typ, source_element_sort,
                   helper_head_var, _tail_var) ->
               ( source_generator.it
               , { Expr_env.term = Var helper_head_var
                 ; sort = source_element_sort
                 ; typ = source_element_typ
                 } ))
      in
      let helper_heads =
        sources
        |> List.map (fun (_, _, _, _, _, _, _, helper_head_var, _) -> helper_head_var)
      in
      let captures =
        body_source_ids
        |> capture_candidates env
        |> make_captures helper_names
      in
      let helper_env =
        capture_env captures
        |> fun env ->
        generator_bindings
        |> List.fold_left
             (fun helper_env (id, binding) ->
               Expr_env.add helper_env id binding)
             env
      in
      let helper_bound =
        helper_heads @ capture_vars captures
      in
      let body_result, names =
        lower_body names ctx helper_env ~bound_vars:helper_bound origin body
      in
      let body_input_bound = helper_bound in
      let body_used_vars =
        let eq_bound =
          Condition_closure.conditions_bound_vars
            helper_heads body_result.eq_conditions
        in
        Condition_closure.external_vars_of_conditions
          helper_heads body_result.eq_conditions
        @ Condition_closure.external_vars_of_rule_conditions
            eq_bound body_result.rule_conditions
        |> List.sort_uniq String.compare
      in
      let captures =
        captures |> filter_used_captures body_used_vars
      in
      let helper_bound =
        helper_heads @ capture_vars captures
      in
      let body_external =
        let eq_external =
          Condition_closure.external_vars_of_conditions
            helper_bound body_result.eq_conditions
        in
        let eq_bound =
          Condition_closure.conditions_bound_vars
            helper_bound body_result.eq_conditions
        in
        eq_external
        @ Condition_closure.external_vars_of_rule_conditions
            eq_bound body_result.rule_conditions
        |> List.sort_uniq String.compare
      in
      let introduced_vars =
        body_result.bound_vars_after
        |> List.filter (fun var -> not (List.mem var body_input_bound))
        |> List.sort_uniq String.compare
      in
      let structural_diagnostics =
        body_external
        |> List.map (fun var_name ->
          unsupported_zip_iter
            ("zip IterPr helper body would need external variable `"
             ^ var_name
             ^ "` after captures; this would not be source-local structural recursion"))
      in
      let helper_rule_conditions =
        List.map (fun condition -> EqCondition condition) body_result.eq_conditions
        @ body_result.rule_conditions
        |> Condition_closure.normalize_rule_conditions
             ~constructor_op:
               (Condition_closure.source_constructor_certificate ctx)
             (List.map (fun var -> Var var) helper_bound)
      in
      let structural_diagnostics =
        match
          Condition_admissibility.rule_conditions_admissible_bound
            ~constructor_op:
              (Condition_closure.source_constructor_certificate ctx)
            helper_bound helper_rule_conditions
        with
        | Some _ -> structural_diagnostics
        | None ->
          unsupported_zip_iter
            "zip IterPr body conditions are not Maude-admissible from the lockstep source heads and captured variables"
          :: structural_diagnostics
      in
      let structural_diagnostics =
        if body_result.has_else then
          unsupported_zip_iter
            "zip IterPr body contains ElsePr; otherwise/complement semantics need a separate source-derived helper"
          :: structural_diagnostics
        else
          structural_diagnostics
      in
      let structural_diagnostics =
        if body_result.let_bound_ids <> [] || introduced_vars <> [] then
          unsupported_zip_iter
            ("zip IterPr body introduces variable(s) that would escape the repeated check: "
             ^ String.concat ", " introduced_vars)
          :: structural_diagnostics
        else
          structural_diagnostics
      in
      if diagnostics_have_fatal body_result.diagnostics
         || structural_diagnostics <> []
      then
        return names
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_guards
          ; diagnostics =
              source_diagnostics @ body_result.diagnostics
              @ structural_diagnostics
          }
      else
        let helper_sources =
          sources
          |> List.map
               (fun (source_generator, source_exp, _source_result, _source_term,
                     source_item_shape, _source_element_typ, source_element_sort,
                     helper_head_var, source_tail_var) ->
                 { Request.source_shape =
                     { generator_source_id = source_generator.it
                     ; source_source = Premise_diagnostic.source_echo_exp source_exp
                     ; source_typ_source = Il.Print.string_of_typ source_exp.note
                     }
                 ; source_item_shape
                 ; helper_head_var
                 ; source_tail_var
                 ; source_element_sort
                 })
        in
        let source_shape =
          { Request.prem_source = Premise_diagnostic.source_echo_prem prem
          ; body_source = Premise_diagnostic.source_echo_prem body
          ; iter_source = Il.Print.string_of_iter iter
          ; sources =
              helper_sources
              |> List.map (fun (source : Request.iter_zip_source) ->
                source.Request.source_shape)
          }
        in
        let source_terms =
          sources
          |> List.map (fun (_, _, _, source_term, _, _, _, _, _) -> source_term)
        in
        let same_length_guards =
          match source_terms with
          | [] | [ _ ] -> []
          | first :: rest ->
            rest
            |> List.map (fun source_term ->
              EqCond (app "len" [ source_term ], app "len" [ first ]))
        in
        let iter_guards, count_diagnostics =
          match iter with
          | List -> Some same_length_guards, []
          | List1 ->
            Some
              (same_length_guards
               @ List.map (fun source_term ->
                   BoolCond (app "_=/=_" [ source_term; Const "eps" ]))
                   source_terms),
            []
          | ListN (n_exp, None) ->
            let n_result = Expr_translate.lower_value ctx env origin n_exp in
            (match n_result.term with
            | Some n_term
              when not (diagnostics_have_fatal n_result.diagnostics)
                   && count_is_total ctx env ~bound_vars origin n_exp ->
              Some
                (n_result.guards
                 @ List.map (fun source_term ->
                     EqCond (app "len" [ source_term ], n_term)) source_terms),
              n_result.diagnostics
            | Some _ | None ->
              None,
              n_result.diagnostics
              @ [ unsupported_zip_iter
                    "zip ListN count did not lower to an admissible Maude term; exact source lengths cannot be enforced"
                ])
          | ListN (_, Some _) | Opt -> None, []
        in
        let caller_eq_conditions =
          Option.map (fun guards -> source_guards @ guards) iter_guards
        in
        let helper_args =
          source_terms @ List.map (fun capture -> capture.Request.call_term) captures
        in
        let helper_missing_vars =
          match caller_eq_conditions with
          | None -> []
          | Some conditions ->
            Condition_closure.external_vars_of_conditions bound_vars conditions
            @ (helper_args
               |> List.concat_map Condition_closure.term_vars
               |> List.filter (fun var ->
                 not
                   (List.mem var
                      (Condition_closure.conditions_bound_vars bound_vars conditions))))
            |> List.sort_uniq String.compare
        in
        let blocked () =
          return names
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_guards
            ; diagnostics =
                source_diagnostics @ body_result.diagnostics @ count_diagnostics
                @ (match helper_missing_vars with
                  | [] -> []
                  | _ ->
                    [ unsupported_zip_iter
                        ("zip IterPr helper call contains variables that are not bound by earlier premise conditions: "
                         ^ String.concat ", " helper_missing_vars)
                    ])
            }
        in
        if diagnostics_have_fatal count_diagnostics
           || helper_missing_vars <> []
        then blocked ()
        else match caller_eq_conditions with
        | None -> blocked ()
        | Some caller_eq_conditions ->
        let helper_request =
          if body_result.rule_conditions = [] then
            { Request.kind =
                Request.Iter_premise_zip_bool
                  { source_shape
                  ; sources = helper_sources
                  ; captures
                  ; body_eq_conditions = body_result.eq_conditions
                  }
            ; reason = "zip IterPr structural Bool helper"
            ; origin
            }
          else
            { Request.kind =
                Request.Iter_premise_zip_rule
                  { source_shape
                  ; sources = helper_sources
                  ; captures
                  ; body_conditions = helper_rule_conditions
                  }
            ; reason = "zip IterPr structural rewrite helper"
            ; origin
            }
        in
        let helper_name = Helper.request (Context.helpers ctx) helper_request in
        let helper_call = app helper_name helper_args in
          let caller_eq_conditions, caller_rule_conditions =
            if body_result.rule_conditions = [] then
              caller_eq_conditions @ [ BoolCond helper_call ], []
            else
              caller_eq_conditions,
              [ RewriteCond
                  ( helper_call
                  , Const (Naming.helper_companion ~role:"premise-zip-ok" helper_name) )
              ]
          in
          let bound_vars_after =
            Condition_closure.conditions_bound_vars
              bound_vars caller_eq_conditions
          in
          return names
            { (empty_with_env ~bound_vars:bound_vars_after env) with
              eq_conditions = caller_eq_conditions
            ; rule_conditions = caller_rule_conditions
            ; runtime_search_requests = body_result.runtime_search_requests
            ; runtime_truth_search_requests = body_result.runtime_truth_search_requests
            ; runtime_truth_worklist_requests = body_result.runtime_truth_worklist_requests
            ; diagnostics =
                source_diagnostics @ body_result.diagnostics @ count_diagnostics
            }

and lower_staged
    names
    ~lower_body
    ~discharge_static_validation
    ctx
    env
    ~bound_vars
    ~future_prems
    ~escape_source_ids
    origin
    ~prem
    ~body
    (iter, generators) =
  match if discharge_static_validation then
    Premise_validation_skip
    .try_skip_iterpr_validation_witness
      ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators
    else None
  with
  | Some result -> result, names
  | None ->
  match
    Premise_iter_binding_map.try_lower
      names
      ~lower_body
      ctx
      env
      ~bound_vars
      origin
      ~prem
      ~body
      iter
      generators
  with
  | Some result -> result
  | None ->
    match iter, generators, body.it with
    | Opt, [ source_generator, source_exp ], IfPr body_exp ->
      ( Premise_iter_opt.lower_ifpr_opt
          ctx
          env
          ~bound_vars
          origin
          ~prem
          ~body:body_exp
          ~source_generator
          ~source_exp
      , names )
    | (List | List1 | ListN (_, None)), [ source_generator, source_exp ], _ ->
      lower_list_iter_premise
        names
        lower_body
        ctx env ~bound_vars origin prem body iter source_generator source_exp
    | (List | List1 | ListN (_, None)), _ :: _ :: _, _ ->
      lower_zip_iter_premise names lower_body ctx env ~bound_vars origin prem body iter generators
    | _ ->
      ( Premise_diagnostic.unsupported_prem
          ctx env ~bound_vars origin "Premise/IterPr" prem
          "iterated premises require all/optional/ListN premise helpers; this slice supports optional IfPr, one-source list all, and flat lockstep list zip helpers"
      , names )

and lower
    names
    ~lower_body
    ~discharge_static_validation
    ctx
    env
    ~bound_vars
    ~future_prems
    ~escape_source_ids
    origin
    ~prem
    ~body
    iterexp =
  let stage = Context.begin_stage ctx in
  let result, candidate_names =
    lower_staged
      names
      ~lower_body
      ~discharge_static_validation
      (Context.staged stage)
      env
      ~bound_vars
      ~future_prems
      ~escape_source_ids
      origin
      ~prem
      ~body
      iterexp
  in
  if diagnostics_have_fatal result.diagnostics then
    Premise_result.blocked_with_env ~bound_vars env result.diagnostics, names
  else (
    Context.commit_stage stage;
    result, candidate_names)
