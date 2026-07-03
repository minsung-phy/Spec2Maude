type head_patterns =
  { terms : Maude_ir.term list option
  ; env : Expr_translate.env
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

type value_components =
  { values : (Maude_ir.term list * Maude_ir.sort list) option
  ; guards : Maude_ir.eq_condition list
  ; diagnostics : Diagnostics.t list
  }

(* Shared rule-component lowering for runtime truth/refutation helpers.

   The refutation path intentionally keeps only head components that lower to a
   source-shaped pattern; missing components are not ordinary success cases and
   this API must stay local to no-hit/refutation materialization. *)

let local_rules request =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  truth_request.Runtime_truth_search_helper.rules
  |> List.filter (fun rule ->
    String.equal
      rule.Analysis.Function_graph.relation_id
      truth_request.Runtime_truth_search_helper.rel_id)

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let exp_components (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.TupE exps -> exps
  | _ -> [ exp ]

let add_pattern_binding env (id, binding) =
  Expr_translate.add_var env id binding

let lower_head_patterns ~require_all ctx origin components =
  let rec loop env terms guards diagnostics = function
    | [] ->
      { terms = Some (List.rev terms)
      ; env
      ; guards = List.rev guards
      ; diagnostics = List.rev diagnostics
      }
    | exp :: exps ->
      let result = Expr_translate.lower_pattern_with_bindings ctx env origin exp in
      let env =
        List.fold_left add_pattern_binding env result.introduced_bindings
      in
      (match result.pattern_term with
      | Some term ->
        loop
          env
          (term :: terms)
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps
      | None when require_all ->
        { terms = None
        ; env
        ; guards = List.rev (List.rev_append result.pattern_guards guards)
        ; diagnostics =
            List.rev (List.rev_append result.pattern_diagnostics diagnostics)
        }
      | None ->
        loop
          env
          terms
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps)
  in
  loop Expr_translate.empty_env [] [] [] components

let lower_complete_head_patterns ctx origin components =
  lower_head_patterns ~require_all:true ctx origin components

let lower_partial_head_patterns_for_acyclic_refutation ctx origin components =
  lower_head_patterns ~require_all:false ctx origin components

let component_sort (exp : Il.Ast.exp) =
  Expr_translate.carrier_sort_of_typ exp.note

let lower_value_components ctx env origin components =
  let rec loop terms sorts guards diagnostics = function
    | [] ->
      { values = Some (List.rev terms, List.rev sorts)
      ; guards = List.rev guards
      ; diagnostics = List.rev diagnostics
      }
    | exp :: exps ->
      (match component_sort exp with
      | None ->
        { values = None
        ; guards = List.rev guards
        ; diagnostics = List.rev diagnostics
        }
      | Some sort ->
        let lowered = Expr_translate.lower_value ctx env origin exp in
        (match lowered.term with
        | Some term ->
          loop
            (term :: terms)
            (sort :: sorts)
            (List.rev_append lowered.guards guards)
            (List.rev_append lowered.diagnostics diagnostics)
            exps
        | None ->
          { values = None
          ; guards = List.rev_append lowered.guards guards
          ; diagnostics = List.rev_append lowered.diagnostics diagnostics
          }))
  in
  loop [] [] [] [] components
