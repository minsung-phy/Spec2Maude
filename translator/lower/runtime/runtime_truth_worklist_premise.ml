open Maude_ir
open Il.Ast
open Util.Source

open Runtime_truth_worklist_core

module Request = Helper_request

let recursive_call ctx item relations env history premise prove =
  match premise with
  | Runtime_truth_scc.Finite_rule_call { relation_id; premise } ->
    (match premise.it, find_relation relations relation_id with
    | RulePr (_, [], _, exp), Some _ ->
      let components = Analysis.Relation_graph.exp_components exp in
      let lowered = Runtime_truth_rule_components.lower_value_components ctx env item.origin components in
      (match lowered.values with
      | Some (terms, _) ->
        let op = if prove then prove_op item relation_id else refute_op item relation_id in
        Some (RewriteCond (App (op, terms @ [ history ]),
                           if prove then
                             (Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request).proved_rhs
                           else
                             (Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request).refuted_rhs),
              lowered.guards, lowered.diagnostics)
      | None -> None)
    | _ -> None)
  | Finite_domain_call _ | Finite_successor_call _ | Deterministic_total _
  | Externally_validated _ | Source_boolean _
  | Deterministic_binding_iter _ | Finite_iter _ -> None

type positive_children =
  { env : Expr_env.t
  ; eq_conditions : eq_condition list
  ; rule_conditions : rule_condition list
  ; diagnostics : Diagnostics.t list
  ; statements : generated list
  ; complete : bool
  }

let rec indexed_component exp =
  match exp.it with
  | IdxE (source, { it = VarE index; _ }) -> Some (source, index.it)
  | SubE (inner, _, _) | CvtE (inner, _, _) -> indexed_component inner
  | _ -> None

let indexed_capture (capture : Request.capture) =
  { Runtime_truth_worklist_indexed.call_term = capture.call_term
  ; formal_var = capture.formal_var
  ; sort = capture.sort
  }

let indexed_edge ctx item relations origin identity env history premise =
  match premise.it with
  | RulePr (rel_id, [], _, exp) ->
    let components = Analysis.Relation_graph.exp_components exp in
    let indexed =
      components
      |> List.mapi (fun index exp -> Option.map (fun pair -> index, pair) (indexed_component exp))
      |> List.filter_map Fun.id
    in
    (match indexed, find_relation relations rel_id.it with
    | [ component_index, (source_exp, index_source_id) ], Some _ ->
      let source = Expr_translate.lower_sequence ctx env origin source_exp in
      (match source.term with
      | None -> None, source.diagnostics
      | Some source_term ->
        let source_ids =
          Il.Free.(free_prem premise).varid
          |> Il.Free.Set.elements
          |> List.filter (fun id -> not (String.equal id index_source_id))
        in
        let names = reserve_names env source_ids [ history ] in
        let source_captures =
          Helper_capture.available_capture_candidates env source_ids
          |> Helper_capture.make_captures names
        in
        let helper_env = Helper_capture.capture_env source_captures in
        let captures = List.map indexed_capture source_captures in
        let history_formal, names =
          Local_name.fresh_qualified_name
            names Local_name.History (sort_ref terminals)
        in
        let history_capture =
          { Runtime_truth_worklist_indexed.call_term = history
          ; formal_var = history_formal
          ; sort = terminals
          }
        in
        let head_var, names =
          Local_name.fresh_qualified_name
            names Local_name.Head (sort_ref terminal)
        in
        let tail_var, _ =
          Local_name.fresh_qualified_name
            names Local_name.Tail (sort_ref terminals)
        in
        let head = Var head_var in
        let values =
          components
          |> List.mapi (fun index component ->
            if index = component_index then Some (head, [], [])
            else
              let lowered = Expr_translate.lower_value ctx helper_env origin component in
              Option.map (fun term -> term, lowered.guards, lowered.diagnostics) lowered.term)
        in
        if List.exists Option.is_none values then None, source.diagnostics
        else
          let values = List.filter_map Fun.id values in
          let terms = List.map (fun (term, _, _) -> term) values in
          let guards = List.concat_map (fun (_, guards, _) -> guards) values in
          let diagnostics = source.diagnostics @ List.concat_map (fun (_, _, ds) -> ds) values in
          let invocation =
            Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request
          in
          let child_history = Var history_formal in
          let indexed =
            Runtime_truth_worklist_indexed.materialize
              { helper_name = item.name
              ; origin
              ; identity
              ; mode = indexed_mode item
              ; source_term
              ; captures = captures @ [ history_capture ]
              ; head_var
              ; tail_var
              ; body_true =
                  List.map (fun guard -> EqCondition guard) guards
                  @ [ RewriteCond
                        (App (prove_op item rel_id.it, terms @ [ child_history ]),
                         invocation.proved_rhs) ]
              ; body_false =
                  (match item.request.mode with
                  | Runtime_truth_worklist_helper.Prove -> []
                  | Decide ->
                    [ List.map (fun guard -> EqCondition guard) guards
                      @ [ RewriteCond
                            (App (refute_op item rel_id.it, terms @ [ child_history ]),
                             invocation.refuted_rhs) ] ])
              ; result_sort = result_sort item
              ; proved = invocation.proved_rhs
              ; refuted = invocation.refuted_rhs
              }
          in
          Some indexed, diagnostics)
    | _ -> None, [])
  | _ -> None, []

let forall_edge ctx item relations origin identity env history premise body_plan =
  let invocation =
    Runtime_truth_worklist_helper.invocation ~helper_name:item.name item.request
  in
  let suffix = Runtime_truth_worklist_indexed.identity_name identity in
  let true_op =
    Naming.helper_companion ~role:("truth-forall-" ^ suffix) item.name
  in
  let false_op =
    Naming.helper_companion ~role:("truth-exists-false-" ^ suffix) item.name
  in
  let result = result_sort item in
  let mode = indexed_mode item in
  let frozen count =
    if count = 0 then [] else [ Frozen (List.init count (fun index -> index + 1)) ]
  in
  let materialize body generators sources =
    let generator_ids = List.map (fun (id, _) -> id.it) generators in
    let capture_ids =
      Il.Free.(free_prem body).varid |> Il.Free.Set.elements
      |> List.filter (fun id -> not (List.mem id generator_ids))
    in
    let names = reserve_names env (generator_ids @ capture_ids) [ history ] in
    let captures =
      capture_ids
      |> Helper_capture.available_capture_candidates env
      |> Helper_capture.make_captures names
    in
    if List.length captures <> List.length capture_ids then None, [] else
    let prepared =
      List.map2 (fun (generator, source)
                      (source_result : Expr_result.result) ->
        match source.note.it, source_result.Expr_result.term with
        | IterT (element_typ, (List | List1 | ListN _)), Some source_term ->
          Expr_translate.carrier_sort_of_typ element_typ
          |> Option.map (fun element_sort ->
            generator, source_result, source_term, element_typ, element_sort)
        | IterT (_, Opt), _ | _, None | _, Some _ -> None)
        generators sources
    in
    if List.exists Option.is_none prepared then
      None, List.concat_map (fun result -> result.Expr_result.diagnostics) sources
    else
      let prepared = List.filter_map Fun.id prepared in
      let head_terms =
        prepared |> List.map (fun (generator, _, _, _, element_sort) ->
          Local_name.source_qualified names generator.it (sort_ref element_sort))
      in
      let tail_terms, names =
        prepared
        |> List.fold_left
             (fun (terms, names) _ ->
               let term, names =
                 Local_name.fresh_qualified names Local_name.Tail
                   (sort_ref terminals)
               in
               term :: terms, names)
             ([], names)
        |> fun (terms, names) -> List.rev terms, names
      in
      let formal_captures =
        captures |> List.map (fun capture -> Var capture.Request.formal_var)
      in
      let history_formal, _names =
        Local_name.fresh_qualified names Local_name.History
          (sort_ref terminals)
      in
      let helper_env =
        List.fold_left2 (fun env (generator, _, _, element_typ, element_sort) head ->
          Expr_env.add env generator.it
            { Expr_env.term = head; sort = element_sort; typ = element_typ })
          (Helper_capture.capture_env captures) prepared head_terms
      in
      let body_true, body_false, body_diagnostics =
        match body_plan with
        | [ Runtime_truth_scc.Finite_rule_call _ as child ] ->
          let true_result = recursive_call ctx item relations helper_env history_formal child true in
          (match mode, true_result with
          | Runtime_truth_worklist_indexed.Prove,
            Some (true_condition, true_guards, true_diagnostics) ->
            ( Some (List.map (fun guard -> EqCondition guard) true_guards
                    @ [ true_condition ])
            , []
            , true_diagnostics )
          | Decide, Some (true_condition, true_guards, true_diagnostics) ->
            (match recursive_call ctx item relations helper_env history_formal child false with
            | Some (false_condition, false_guards, false_diagnostics) ->
            ( Some (List.map (fun guard -> EqCondition guard) true_guards
                    @ [ true_condition ])
            , [ List.map (fun guard -> EqCondition guard) false_guards
                @ [ false_condition ] ]
            , true_diagnostics @ false_diagnostics )
            | None -> None, [], true_diagnostics)
          | _ -> None, [], [])
        | [ Runtime_truth_scc.Source_boolean ({ it = IfPr exp; _ } as prem) ] ->
          let positive =
            Premise_translate.translate_premises
              ~allow_runtime_search:false ~discharge_static_validation:true
              ctx helper_env ~bound_terms:(head_terms @ formal_captures)
              origin [ prem ]
          in
          (match positive with
          | Premise_result.Blocked diagnostics
          | Deferred (_, diagnostics) -> None, [], diagnostics
          | Complete positive ->
            let false_result =
              match mode with
              | Runtime_truth_worklist_indexed.Prove -> Ok ([], [])
              | Decide ->
                (match
                   Runtime_truth_condition_complement.source_boolean_alternatives
                     ctx helper_env origin exp
                 with
                | Ok proof -> Ok (proof.failures, proof.diagnostics)
                | Error blockers ->
                  Error
                    (List.map
                       (Runtime_truth_totality.diagnostic ctx) blockers))
            in
            (match false_result with
            | Ok (alternatives, diagnostics)
              when not (Premise_result.has_else positive)
                   && Premise_result.runtime_search_requests positive = []
                   && Premise_result.runtime_truth_search_requests positive = []
                   && Premise_result.runtime_truth_worklist_requests positive = [] ->
              ( Some
                  (List.map (fun condition -> EqCondition condition)
                     (Premise_result.eq_conditions positive)
                   @ Premise_result.rule_conditions positive)
              , List.map
                  (List.map (fun condition -> EqCondition condition)) alternatives
              , Premise_result.diagnostics positive @ diagnostics )
            | Ok (_, diagnostics) ->
              None, [], Premise_result.diagnostics positive @ diagnostics
            | Error diagnostics ->
              None, [], Premise_result.diagnostics positive @ diagnostics))
        | [ Runtime_truth_scc.Source_boolean _ ] -> None, [], []
        | [ Runtime_truth_scc.Externally_validated _ ] -> Some [], [], []
        | [ Runtime_truth_scc.Deterministic_total _
          | Runtime_truth_scc.Deterministic_binding_iter _
          | Runtime_truth_scc.Finite_domain_call _
          | Runtime_truth_scc.Finite_successor_call _
          | Runtime_truth_scc.Finite_iter _ ] -> None, [], []
        | [] | _ :: _ :: _ -> None, [], []
      in
      match body_true with
      | None -> None, body_diagnostics
      | Some body_true ->
        let source_terms =
          prepared |> List.map (fun (_, _, term, _, _) -> term)
        in
        let source_guards =
          prepared |> List.concat_map (fun (_, result, _, _, _) -> result.Expr_result.guards)
        in
        let source_diagnostics =
          prepared |> List.concat_map (fun (_, result, _, _, _) -> result.Expr_result.diagnostics)
        in
        if source_guards <> [] then
          None,
          source_diagnostics @ body_diagnostics
          @ [ diagnostic ctx item origin
                "RuntimeTruthWorklist/IterPr/source-guards"
                "finite IterPr generator source requires guards that cannot be attached to the worklist call atomically"
                "Keep this iterator Unsupported until its complete source-domain guards have an explicit helper entry rule"
                (Some (Il.Print.string_of_prem premise)) ]
        else
        let actual_captures =
          captures |> List.map (fun capture -> capture.Request.call_term)
        in
        let actual_args = source_terms @ actual_captures @ [ history ] in
        let formal_args = formal_captures @ [ history_formal ] in
        let call op sources = App (op, sources @ formal_args) in
        let actual_call op = App (op, actual_args) in
        let empty = List.map (fun _ -> Const "eps") prepared in
        let cons = List.map2 (fun head tail -> App ("_ _", [ head; tail ])) head_terms tail_terms in
        let declarations =
          [ generated item origin
              (op true_op
                 (List.map (fun _ -> sort_ref terminals) prepared
                  @ List.map (fun capture -> sort_ref capture.Request.sort) captures
                  @ [ sort_ref terminals ])
                 result ~attrs:(frozen (List.length prepared + List.length captures + 1))) ]
          @ (match mode with
             | Runtime_truth_worklist_indexed.Prove -> []
             | Decide ->
               [ generated item origin
                   (op false_op
                      (List.map (fun _ -> sort_ref terminals) prepared
                       @ List.map (fun capture -> sort_ref capture.Request.sort) captures
                       @ [ sort_ref terminals ])
                      result ~attrs:(frozen (List.length prepared + List.length captures + 1))) ])
        in
        let true_rules =
          [ generated item origin
              (rl ~label:(true_op ^ "-empty")
                 (call true_op empty) invocation.proved_rhs)
          ; generated item origin
              (crl ~label:(true_op ^ "-cons")
                 (call true_op cons) invocation.proved_rhs
                 (body_true
                  @ [ RewriteCond (call true_op tail_terms, invocation.proved_rhs) ]))
          ]
        in
        let false_rules =
          match mode with
          | Runtime_truth_worklist_indexed.Prove -> []
          | Decide ->
            (body_false |> List.mapi (fun index conditions ->
               generated item origin
                 (crl ~label:(false_op ^ "-head-" ^ string_of_int (index + 1))
                    (call false_op cons) invocation.refuted_rhs conditions)))
            @ [ generated item origin
                  (crl ~label:(false_op ^ "-tail")
                     (call false_op cons) invocation.refuted_rhs
                     [ RewriteCond (call false_op tail_terms, invocation.refuted_rhs) ]) ]
            @ (prepared |> List.mapi (fun left _ ->
                 prepared |> List.filteri (fun right _ -> left <> right)
                 |> List.mapi (fun right _ ->
                   let right = if right >= left then right + 1 else right in
                   let mismatch =
                     prepared |> List.mapi (fun index _ ->
                       if index = left then Const "eps"
                       else if index = right then List.nth cons index
                       else List.nth tail_terms index)
                   in
                   generated item origin
                     (rl ~label:(false_op ^ "-length-" ^ string_of_int left ^ "-" ^ string_of_int right)
                        (call false_op mismatch) invocation.refuted_rhs)))
               |> List.concat)
        in
        Some
          { Runtime_truth_worklist_indexed.statements = declarations @ true_rules @ false_rules
          ; true_condition =
              RewriteCond (actual_call true_op, invocation.proved_rhs)
          ; false_condition =
              (match mode with
              | Runtime_truth_worklist_indexed.Prove -> None
              | Decide -> Some (RewriteCond (actual_call false_op, invocation.refuted_rhs)))
             }, source_diagnostics @ body_diagnostics @
             Condition_admissibility.crl_admissibility_diagnostics
               ~constructor_op:(helper_pattern_certificate ctx item)
               ctx origin (actual_call true_op) invocation.proved_rhs
               (List.map (fun guard -> EqCondition guard) source_guards)
  in
  match premise.it with
  | IterPr (body, (List, generators)) when generators <> [] ->
    let sources =
      generators |> List.map (fun (_, source) ->
        Expr_translate.lower_sequence ctx env origin source)
    in
    materialize body generators sources
  | IterPr (_, ((Opt | List1 | ListN _), _))
  | IterPr (_, (List, _))
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | NegPr _ -> None, []

let lower_positive_children
    ctx item relations origin phase rule_index head_terms head_env history premises =
  let rec lower state = function
    | [] -> state
    | (_, (Runtime_truth_scc.Finite_rule_call _ as premise)) :: rest ->
      (match recursive_call ctx item relations state.env history premise true with
      | None -> { state with complete = false }
      | Some (condition, guards, diagnostics) ->
        lower
          { state with
            eq_conditions = state.eq_conditions @ guards
          ; rule_conditions = state.rule_conditions @ [ condition ]
          ; diagnostics = state.diagnostics @ diagnostics
          ; statements = state.statements
          }
          rest)
    | (_premise_index, Runtime_truth_scc.Externally_validated prem) :: rest ->
      let skipped =
        Premise_diagnostic.skipped_prem
          ctx state.env ~bound_vars:[] origin
          "RuntimeTruthWorklist/external-validation-certificate" prem
          "runtime-demanded validation leaf is discharged by an exact marker-result and no-runtime-escape certificate"
          "Retain this source premise in provenance; the externally validated runtime profile guarantees it before execution"
      in
      lower
        { state with diagnostics = state.diagnostics @ skipped.diagnostics }
        rest
    | (_premise_index, (Runtime_truth_scc.Deterministic_total prem
      | Runtime_truth_scc.Source_boolean prem
      | Runtime_truth_scc.Deterministic_binding_iter prem)) :: rest ->
      let result =
        Premise_translate.translate_premises
          ~allow_runtime_search:false
          ~discharge_static_validation:true
          ctx state.env
          ~bound_conditions:state.eq_conditions
          ~bound_terms:head_terms
          origin [ prem ]
      in
      (match result with
      | Premise_result.Blocked diagnostics
      | Deferred (_, diagnostics) ->
        { state with
          diagnostics = state.diagnostics @ diagnostics
        ; complete = false
        }
      | Complete result ->
        if Premise_result.has_else result
           || Premise_result.runtime_search_requests result <> []
           || Premise_result.runtime_truth_search_requests result <> []
           || Premise_result.runtime_truth_worklist_requests result <> []
        then
          { state with
            diagnostics = state.diagnostics @ Premise_result.diagnostics result
          ; complete = false
          }
        else
          lower
            { env = Premise_result.env_after result
            ; eq_conditions =
                state.eq_conditions @ Premise_result.eq_conditions result
            ; rule_conditions =
                state.rule_conditions @ Premise_result.rule_conditions result
            ; diagnostics =
                state.diagnostics @ Premise_result.diagnostics result
            ; statements = state.statements
            ; complete = state.complete
            }
            rest)
    | (premise_index, Runtime_truth_scc.Finite_iter finite) :: rest ->
      let identity =
        { Runtime_truth_worklist_indexed.phase = phase
        ; rule_index
        ; premise_index = Some premise_index
        }
      in
      let edge, diagnostics =
        match indexed_edge ctx item relations origin identity
                state.env history finite.premise with
        | Some indexed, diagnostics -> Some indexed, diagnostics
        | None, diagnostics ->
          let forall, forall_diagnostics =
            forall_edge ctx item relations origin identity state.env history
              finite.premise finite.body
          in
          forall, diagnostics @ forall_diagnostics
      in
      (match edge, diagnostics with
      | Some indexed, diagnostics ->
        lower
          { state with
            rule_conditions = state.rule_conditions @ [ indexed.true_condition ]
          ; diagnostics = state.diagnostics @ diagnostics
          ; statements = state.statements @ indexed.statements
          }
          rest
      | None, diagnostics ->
        { state with diagnostics = state.diagnostics @ diagnostics; complete = false })
    | (_, Runtime_truth_scc.Finite_domain_call _) :: rest ->
      lower state rest
    | (_, Runtime_truth_scc.Finite_successor_call _) :: _ ->
      { state with complete = false }
  in
  lower
    { env = head_env
    ; eq_conditions = []
    ; rule_conditions = []
    ; diagnostics = []
    ; statements = []
    ; complete = true
    }
    premises
