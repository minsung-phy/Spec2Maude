open Il.Ast
open Maude_ir
open Util.Source

open Premise_capture
open Premise_iter_support

type lower_body = Premise_iter_support.lower_body

let rec lower_list_iter_premise
    lower_body
    ctx env ~bound_vars origin prem body iter source_generator source_exp =
  let unsupported_list_iter reason =
    unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/List"
      ~source_echo:(source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the repeated premise can be lowered as source-shaped structural recursion without search or rewrite conditions"
      ()
  in
  match flat_list_element_typ source_exp.note with
  | None ->
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
              @ [ unsupported_list_iter
                    "list IterPr source is not bound before the helper call; emitting a Bool helper condition would create a Maude used-before-bound variable"
                ]
          }
        else
          let stem = helper_local_stem origin (source_echo_prem prem) in
          let helper_head_var = "HEAD" ^ stem in
          let source_tail_var = "TAIL" ^ stem in
          let generator_binding =
            { Expr_translate.term = Var helper_head_var
            ; sort = source_element_sort
            ; typ = source_element_typ
            }
          in
          let body_source_ids =
            prem_free_var_ids body
            |> List.filter (fun id -> id <> source_generator.it)
            |> List.sort_uniq String.compare
          in
          let captures =
            body_source_ids
            |> capture_candidates env
            |> make_captures stem
          in
          let helper_env =
            Expr_translate.add_var
              (capture_env captures)
              source_generator.it
              generator_binding
          in
          let helper_bound =
            helper_head_var :: capture_vars captures
          in
          let body_result =
            lower_body helper_env ~bound_vars:helper_bound origin body
          in
          let body_input_bound = helper_bound in
          let body_used_vars =
            Condition_closure.external_vars_of_conditions
              [ helper_head_var ]
              body_result.eq_conditions
          in
          let captures =
            captures |> filter_used_captures body_used_vars
          in
          let helper_bound =
            helper_head_var :: capture_vars captures
          in
          let body_external =
            Condition_closure.external_vars_of_conditions
              helper_bound
              body_result.eq_conditions
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
          let structural_diagnostics =
            if body_result.rule_conditions <> [] then
              unsupported_list_iter
                "list IterPr body lowers to a rewrite condition; rewrite conditions cannot appear inside this Bool helper equation"
              :: structural_diagnostics
            else
              structural_diagnostics
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
            { (empty_with_env ~bound_vars env) with
              eq_conditions = source_result.guards
            ; diagnostics =
                source_result.diagnostics @ body_result.diagnostics
                @ structural_diagnostics
            }
          else
            let helper_request =
              { Helper.kind =
                  Helper.Iter_premise_list_bool
                    { source_shape =
                        { prem_source = source_echo_prem prem
                        ; body_source = source_echo_prem body
                        ; source_source = source_echo_exp source_exp
                        ; source_typ_source = Il.Print.string_of_typ source_exp.note
                        ; iter_source = Il.Print.string_of_iter iter
                        }
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
            in
            let helper_name =
              Helper.request (Context.helpers ctx) helper_request
            in
            let helper_call =
              app helper_name
                (source_term
                 :: List.map (fun capture -> capture.Helper.call_term) captures)
            in
            let iter_guards =
              match iter with
              | List -> []
              | List1 -> [ BoolCond (app "_=/=_" [ source_term; Const "eps" ]) ]
              | ListN (n_exp, None) ->
                let n_result = Expr_translate.lower_value ctx env origin n_exp in
                (match n_result.term with
                | Some n_term ->
                  n_result.guards @ [ EqCond (app "len" [ source_term ], n_term) ]
                | None -> n_result.guards)
              | ListN (_, Some _) | Opt -> []
            in
            let caller_conditions =
              source_result.guards @ iter_guards @ [ BoolCond helper_call ]
            in
            let helper_missing_vars =
              Condition_closure.external_vars_of_conditions
                bound_vars
                caller_conditions
            in
            if helper_missing_vars = [] then
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
                  @ [ unsupported_list_iter
                        ("list IterPr helper call contains variables that are not bound by earlier premise conditions: "
                         ^ String.concat ", " helper_missing_vars)
                    ]
              }))

and lower_zip_iter_premise lower_body ctx env ~bound_vars origin prem body iter generators =
  let unsupported_zip_iter reason =
    unsupported
      ~ctx ~origin ~constructor:"Premise/IterPr/Zip"
      ~source_echo:(source_echo_prem prem)
      ~reason
      ~suggestion:
        "Keep this IterPr Unsupported until the lockstep repeated premise can be lowered as source-shaped structural recursion without search or rewrite conditions"
      ()
  in
  let stem = helper_local_stem origin (source_echo_prem prem) in
  let generator_ids = generators |> List.map (fun (id, _exp) -> id.it) in
  let lower_source index (source_generator, source_exp) =
    match zip_source_descriptor source_exp.note with
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
          let suffix =
            "_"
            ^ Naming.maude_var
                ~fallback:("GEN" ^ string_of_int index)
                source_generator.it
          in
          Ok
            ( source_generator
            , source_exp
            , source_result
            , source_term
            , source_item_shape
            , source_element_typ
            , source_element_sort
            , "HEAD" ^ stem ^ suffix
            , "TAIL" ^ stem ^ suffix )))
  in
  let rec collect index acc diagnostics = function
    | [] ->
      if diagnostics = [] then Ok (List.rev acc) else Error diagnostics
    | generator :: generators ->
      (match lower_source index generator with
      | Ok source -> collect (index + 1) (source :: acc) diagnostics generators
      | Error source_diagnostics ->
        collect (index + 1) acc (diagnostics @ source_diagnostics) generators)
  in
  match collect 0 [] [] generators with
  | Error diagnostics ->
    { (empty_with_env ~bound_vars env) with diagnostics }
  | Ok sources ->
    let source_guards =
      sources
      |> List.concat_map (fun (_, _, source_result, _, _, _, _, _, _) ->
        source_result.Expr_translate.guards)
    in
    let source_diagnostics =
      sources
      |> List.concat_map (fun (_, _, source_result, _, _, _, _, _, _) ->
        source_result.Expr_translate.diagnostics)
    in
    let source_bound = conditions_bound_vars bound_vars source_guards in
    let unbound_source_vars =
      sources
      |> List.concat_map (fun (_id, _exp, _source_result, source_term, _, _, _, _, _) ->
        Condition_closure.term_vars source_term)
      |> List.filter (fun var -> not (List.mem var source_bound))
      |> List.sort_uniq String.compare
    in
    if unbound_source_vars <> [] then
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
               , { Expr_translate.term = Var helper_head_var
                 ; sort = source_element_sort
                 ; typ = source_element_typ
                 } ))
      in
      let helper_heads =
        sources
        |> List.map (fun (_, _, _, _, _, _, _, helper_head_var, _) -> helper_head_var)
      in
      let body_source_ids =
        prem_free_var_ids body
        |> List.filter (fun id -> not (List.mem id generator_ids))
        |> List.sort_uniq String.compare
      in
      let captures =
        body_source_ids
        |> capture_candidates env
        |> make_captures stem
      in
      let helper_env =
        capture_env captures
        |> fun env ->
        generator_bindings
        |> List.fold_left
             (fun helper_env (id, binding) ->
               Expr_translate.add_var helper_env id binding)
             env
      in
      let helper_bound =
        helper_heads @ capture_vars captures
      in
      let body_result =
        lower_body helper_env ~bound_vars:helper_bound origin body
      in
      let body_input_bound = helper_bound in
      let body_used_vars =
        Condition_closure.external_vars_of_conditions
          helper_heads
          body_result.eq_conditions
      in
      let captures =
        captures |> filter_used_captures body_used_vars
      in
      let helper_bound =
        helper_heads @ capture_vars captures
      in
      let body_external =
        Condition_closure.external_vars_of_conditions
          helper_bound
          body_result.eq_conditions
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
      let structural_diagnostics =
        if body_result.rule_conditions <> [] then
          unsupported_zip_iter
            "zip IterPr body lowers to a rewrite condition; rewrite conditions cannot appear inside this Bool helper equation"
          :: structural_diagnostics
        else
          structural_diagnostics
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
                 { Helper.source_shape =
                     { generator_source_id = source_generator.it
                     ; source_source = source_echo_exp source_exp
                     ; source_typ_source = Il.Print.string_of_typ source_exp.note
                     }
                 ; source_item_shape
                 ; helper_head_var
                 ; source_tail_var
                 ; source_element_sort
                 })
        in
        let helper_request =
          { Helper.kind =
              Helper.Iter_premise_zip_bool
                { source_shape =
                    { prem_source = source_echo_prem prem
                    ; body_source = source_echo_prem body
                    ; iter_source = Il.Print.string_of_iter iter
                    ; sources =
                        helper_sources
                        |> List.map (fun (source : Helper.iter_zip_source) ->
                          source.Helper.source_shape)
                    }
                ; sources = helper_sources
                ; captures
                ; body_eq_conditions = body_result.eq_conditions
                }
          ; reason = "zip IterPr structural Bool helper"
          ; origin
          }
        in
        let helper_name = Helper.request (Context.helpers ctx) helper_request in
        let helper_call =
          app helper_name
            ((sources
              |> List.map (fun (_, _, _, source_term, _, _, _, _, _) -> source_term))
             @ List.map (fun capture -> capture.Helper.call_term) captures)
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
        let iter_guards =
          match iter with
          | List -> same_length_guards
          | List1 ->
            same_length_guards
            @ (source_terms
               |> List.map (fun source_term ->
                 BoolCond (app "_=/=_" [ source_term; Const "eps" ])))
          | ListN (n_exp, None) ->
            let n_result = Expr_translate.lower_value ctx env origin n_exp in
            (match n_result.term with
            | Some n_term ->
              n_result.guards
              @ (sources
                 |> List.map (fun (_, _, _, source_term, _, _, _, _, _) ->
                   EqCond (app "len" [ source_term ], n_term)))
            | None -> n_result.guards)
          | ListN (_, Some _) | Opt -> []
        in
        let caller_conditions =
          source_guards @ iter_guards @ [ BoolCond helper_call ]
        in
        let helper_missing_vars =
          Condition_closure.external_vars_of_conditions
            bound_vars
            caller_conditions
        in
        if helper_missing_vars = [] then
          with_conditions
            env
            bound_vars
            caller_conditions
            (source_diagnostics @ body_result.diagnostics)
        else
          { (empty_with_env ~bound_vars env) with
            eq_conditions = source_guards
          ; diagnostics =
              source_diagnostics @ body_result.diagnostics
              @ [ unsupported_zip_iter
                    ("zip IterPr helper call contains variables that are not bound by earlier premise conditions: "
                     ^ String.concat ", " helper_missing_vars)
                ]
          }

and lower
    ~lower_body
    ctx
    env
    ~bound_vars
    ~future_prems
    ~escape_source_ids
    origin
    ~prem
    ~body
    (iter, generators) =
  match
    Premise_runtime_after_external_validation_skip
    .try_skip_iterpr_validation_witness
      ctx env ~bound_vars ~future_prems ~escape_source_ids origin prem body iter generators
  with
  | Some result -> result
  | None ->
  match
    Premise_iter_binding_map.try_lower
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
      Premise_iter_opt.lower_ifpr_opt
        ctx
        env
        ~bound_vars
        origin
        ~prem
        ~body:body_exp
        ~source_generator
        ~source_exp
    | (List | List1 | ListN (_, None)), [ source_generator, source_exp ], _ ->
      lower_list_iter_premise
        lower_body
        ctx env ~bound_vars origin prem body iter source_generator source_exp
    | (List | List1 | ListN (_, None)), _ :: _ :: _, _ ->
      lower_zip_iter_premise lower_body ctx env ~bound_vars origin prem body iter generators
    | _ ->
      unsupported_prem ctx env ~bound_vars origin "Premise/IterPr" prem
        "iterated premises require all/optional/ListN premise helpers; this slice supports optional IfPr, one-source list all, and flat lockstep list zip helpers"
