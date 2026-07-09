open Il.Ast
open Maude_ir
open Util.Source

open Premise_capture
include Premise_result

let unsupported = Premise_diagnostic.unsupported
let skipped = Premise_diagnostic.skipped
let source_echo_prem = Premise_diagnostic.source_echo_prem
let source_echo_exp = Premise_diagnostic.source_echo_exp
let unsupported_prem = Premise_diagnostic.unsupported_prem

let vars_subset = Condition_closure.vars_subset
let flat_list_element_typ = Premise_shape.flat_list_element_typ
let with_conditions = Premise_state.with_conditions

let app name args =
  App (name, args)

let relation_call rel_id inputs =
  App (Naming.relation_op rel_id, inputs)

let rec nth_opt items index =
  match items, index with
  | item :: _, 0 -> Some item
  | _ :: rest, index when index > 0 -> nth_opt rest (index - 1)
  | _ -> None

let rec is_direct_var_exp var exp =
  match exp.it with
  | VarE id -> id.it = var
  | OptE (Some inner) -> is_direct_var_exp var inner
  | _ -> false

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

let runtime_predicate_var_term ~bound_vars source_id sort =
  let raw_var = Naming.maude_var source_id in
  let typed_var = raw_var ^ ":" ^ sort_name sort in
  if List.mem typed_var bound_vars then
    Var typed_var
  else if List.mem raw_var bound_vars then
    Var raw_var
  else
    Var typed_var

let rec lower_runtime_predicate_value ctx env ~bound_vars origin exp =
  match exp.it with
  | VarE id when Expr_translate.find_var env id.it = None ->
    (match Expr_translate.carrier_sort_of_typ exp.note with
    | Some sort ->
      { Expr_translate.term =
          Some (runtime_predicate_var_term ~bound_vars id.it sort)
      ; guards = []
      ; diagnostics = []
      }
    | None -> Expr_translate.lower_value ctx env origin exp)
  | IdxE (base, index_exp) ->
    let base_result =
      lower_runtime_predicate_value
        ctx
        env
        ~bound_vars
        (Origin.with_child
           origin
           "idx-base"
           ~ast_constructor:"Expr/IdxE"
           base.at
           ~source_echo:(Il.Print.string_of_exp base))
        base
    in
    let index_result =
      lower_runtime_predicate_value
        ctx
        env
        ~bound_vars
        (Origin.with_child
           origin
           "idx-index"
           ~ast_constructor:"Expr/IdxE"
           index_exp.at
           ~source_echo:(Il.Print.string_of_exp index_exp))
        index_exp
    in
    (match base_result.term, index_result.term with
    | Some base_term, Some index_term ->
      { Expr_translate.term = Some (app "index" [ base_term; index_term ])
      ; guards = base_result.guards @ index_result.guards
      ; diagnostics = base_result.diagnostics @ index_result.diagnostics
      }
    | _ ->
      { Expr_translate.term = None
      ; guards = base_result.guards @ index_result.guards
      ; diagnostics = base_result.diagnostics @ index_result.diagnostics
      })
  | SubE (inner, _source_typ, _target_typ) ->
    lower_runtime_predicate_value ctx env ~bound_vars origin inner
  | CvtE (inner, _source_typ, _target_typ) ->
    lower_runtime_predicate_value ctx env ~bound_vars origin inner
  | _ -> Expr_translate.lower_value ctx env origin exp

let lower_runtime_predicate_value_components ctx env ~bound_vars origin exps =
  let results =
    exps |> List.map (lower_runtime_predicate_value ctx env ~bound_vars origin)
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

type runtime_predicate_analysis =
  | Runtime_predicate_ready of
      { guards : eq_condition list
      ; predicate_term : term
      ; components : exp list
      ; terms : term list
      ; input_sorts : sort list option
      ; bound_after_guards : string list
      ; diagnostics : Diagnostics.t list
      }
  | Runtime_predicate_needs_binding of
      { guards : eq_condition list
      ; diagnostics : Diagnostics.t list
      ; components : exp list
      ; terms : term list
      ; missing_sources : string list
      ; reason : string
      ; suggestion : string
      }
  | Runtime_predicate_bad_value of
      { guards : eq_condition list
      ; diagnostics : Diagnostics.t list
      }

let runtime_predicate_unsupported
    ?(blocked_witness_source_ids = [])
    ctx env ~bound_vars origin prem constructor diagnostics guards reason suggestion =
  { (empty_with_env ~bound_vars env) with
    eq_conditions = guards
  ; blocked_witness_source_ids
  ; diagnostics =
      diagnostics
      @ [ unsupported
            ~ctx
            ~origin
            ~constructor
            ~source_echo:(source_echo_prem prem)
            ~reason
            ~suggestion
        ()
        ]
  }

let runtime_predicate_blocked_by_prior_witness
    ctx env ~bound_vars origin prem diagnostics guards missing_sources =
  { (empty_with_env ~bound_vars env) with
    eq_conditions = guards
  ; diagnostics =
      diagnostics
      @ [ skipped
            ~ctx
            ~origin
            ~constructor:"Premise/RulePr/runtime-predicate/blocked-by-witness-search"
            ~source_echo:(source_echo_prem prem)
            ~reason:
              ("this predicate uses witness variable(s) that an earlier premise in the same source block was supposed to introduce, but that earlier witness search is still Unsupported: "
               ^ String.concat ", " missing_sources)
            ~suggestion:
              "Implement the earlier source-derived rewrite-backed local-existential helper; this dependent predicate will then be checked after the witness is introduced"
            ()
        ]
  }

let runtime_predicate_missing_sources bound components terms =
  List.combine components terms
  |> List.concat_map (fun (component, term) ->
    let missing =
      Condition_closure.term_vars term
      |> List.filter (fun var -> not (List.mem var bound))
    in
    if missing = [] then
      []
    else
      source_and_note_free_var_ids component)
  |> List.sort_uniq String.compare

let runtime_predicate_input_sorts components =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | component :: components ->
      (match Expr_translate.carrier_sort_of_typ component.note with
      | Some sort -> loop (sort :: acc) components
      | None -> None)
  in
  loop [] components

let analyze_runtime_predicate_args
    ctx env ~bound_vars origin rel_id exp relation_shape =
  let expected_count = List.length relation_shape.Relation_shape.components in
  match Analysis.Relation_graph.exp_components_for_count expected_count exp with
  | None ->
    Error
      (Printf.sprintf
         "runtime predicate relation premise does not match the referenced RelD signature component count %d without flattening source tuple structure"
         expected_count)
  | Some components ->
    let terms_opt, guards, diagnostics =
      lower_runtime_predicate_value_components ctx env ~bound_vars origin components
    in
    let guards =
      Condition_closure.normalize_binding_conditions
        (bound_vars |> List.map (fun var -> Var var))
        guards
    in
    match terms_opt with
    | None -> Ok (Runtime_predicate_bad_value { guards; diagnostics })
    | Some terms ->
      (match Condition_closure.conditions_admissible_bound bound_vars guards with
      | None ->
        Ok
          (Runtime_predicate_needs_binding
             { guards
             ; diagnostics
             ; components
             ; terms
             ; missing_sources = runtime_predicate_missing_sources bound_vars components terms
             ; reason =
                 "runtime predicate argument guards are not admissible from variables bound by the enclosing lhs or earlier premises; Bool predicates cannot introduce or search for their arguments"
             ; suggestion =
                 "Bind the predicate arguments through the source lhs or an earlier admissible premise; if the source premise needs an existential witness, lower it through a source-derived rewrite-backed search helper, not through a Bool predicate or single-witness function"
             })
      | Some bound_after_guards ->
        let predicate_term = relation_call rel_id terms in
        let missing =
          Condition_closure.term_vars predicate_term
          |> List.filter (fun var -> not (List.mem var bound_after_guards))
          |> List.sort_uniq String.compare
        in
        if missing = [] then
          Ok
            (Runtime_predicate_ready
               { guards
               ; predicate_term
               ; components
               ; terms
               ; input_sorts = runtime_predicate_input_sorts components
               ; bound_after_guards
               ; diagnostics
               })
        else
          Ok
            (Runtime_predicate_needs_binding
               { guards
               ; diagnostics
               ; components
               ; terms
               ; missing_sources =
                   runtime_predicate_missing_sources bound_after_guards components terms
               ; reason =
                   "runtime predicate premise would need to bind/search variable(s), but Bool predicates can only test already-bound values in Maude conditions: "
                   ^ String.concat ", " missing
               ; suggestion =
                   "Do not encode this predicate as a matching condition or deterministic witness function; keep it Unsupported until a source-derived rewrite-backed local-existential helper can introduce the witness before later guards use it"
               }))

let local_witness_arguments missing_sources components terms =
  match missing_sources with
  | [ witness_source_id ] ->
    let component_sort component =
      Expr_translate.carrier_sort_of_typ component.note
    in
    let rec terms_with_sorts components terms =
      match components, terms with
      | [], [] -> Some []
      | component :: components, term :: terms ->
        (match component_sort component, terms_with_sorts components terms with
        | Some sort, Some rest -> Some ((term, sort) :: rest)
        | None, _ | _, None -> None)
      | _ -> None
    in
    let rec loop index inputs_rev = function
      | [], [] -> None
      | component :: components, term :: terms ->
        (match component.it with
        | VarE id when id.it = witness_source_id ->
          (match component_sort component with
          | None -> None
          | Some witness_sort ->
            (match terms_with_sorts components terms with
            | None -> None
            | Some rest ->
              let input_pairs = List.rev inputs_rev @ rest in
              Some
                ( List.map fst input_pairs
                , List.map snd input_pairs
                , index
                , term
                , witness_sort )))
        | _ ->
          (match component_sort component with
          | None -> None
          | Some sort -> loop (index + 1) ((term, sort) :: inputs_rev) (components, terms)))
      | _ -> None
    in
    loop 0 [] (components, terms)
  | _ -> None

let runtime_predicate_relation ctx rel_id mixop =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id with
  | None -> None
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let local_kind = Analysis.Relation_graph.classify_mixop mixop in
    let runtime_predicate =
      local_kind = relation_shape.Relation_shape.marker
      && Analysis.Relation_graph.eq_mixop relation.mixop mixop
      &&
      match relation_shape.Relation_shape.decision with
      | Relation_shape.Runtime_predicate _ -> true
      | Relation_shape.Static_validation _ ->
        Analysis.Function_graph.relation_is_runtime_demanded
          (Context.function_graph ctx)
          rel_id
      | Relation_shape.Deterministic_candidate _
      | Relation_shape.Execution _
      | Relation_shape.Unknown _ -> false
    in
    if runtime_predicate then Some relation_shape else None

let direct_witness_index witness_source_id components =
  let rec loop index = function
    | [] -> None
    | component :: components ->
      if is_direct_var_exp witness_source_id component then
        Some index
      else
        loop (index + 1) components
  in
  loop 0 components

let local_witness_guides
    ctx
    env
    ~bound_vars
    origin
    ~witness_source_id
    ~witness_term
    ~witness_sort
    future_prems
  =
  let guide_of_prem prem =
    match prem.it with
    | RulePr (rel_id, [], mixop, exp) ->
      (match runtime_predicate_relation ctx rel_id.it mixop with
      | None -> None
      | Some relation_shape ->
        let expected_count =
          List.length relation_shape.Relation_shape.components
        in
        (match Analysis.Relation_graph.exp_components_for_count expected_count exp with
        | None -> None
        | Some components ->
          (match direct_witness_index witness_source_id components with
          | None -> None
          | Some guide_witness_index ->
            (match nth_opt components guide_witness_index with
            | None -> None
            | Some guide_witness ->
              let witness_binding =
                { Expr_translate.term = witness_term
                ; sort = witness_sort
                ; typ = guide_witness.note
                }
              in
              let guide_env =
                Expr_translate.with_condition_bound_vars
                  (Expr_translate.add_var env witness_source_id witness_binding)
                  bound_vars
              in
              let terms_opt, guards, diagnostics =
                lower_value_components ctx guide_env origin components
              in
              (match
                 ( terms_opt
                 , guards
                 , diagnostics
                 , runtime_predicate_input_sorts components )
               with
              | Some guide_input_terms, [], [], Some guide_input_sorts ->
                Some
                  { Runtime_search_helper.guide_rel_id = rel_id.it
                  ; guide_source = Some (source_echo_prem prem)
                  ; guide_input_terms
                  ; guide_input_sorts
                  ; guide_witness_index
                  }
              | _ -> None)))))
    | RulePr (_, _ :: _, _, _)
    | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None
  in
  future_prems |> List.filter_map guide_of_prem

let rec replace_term needle replacement term =
  if term = needle then
    replacement
  else
    match term with
    | Var _ | Const _ | Qid _ -> term
    | App (op, args) -> App (op, List.map (replace_term needle replacement) args)

let replace_condition needle replacement = function
  | EqCond (left, right) ->
    EqCond (replace_term needle replacement left, replace_term needle replacement right)
  | MatchCond (left, right) ->
    MatchCond (replace_term needle replacement left, replace_term needle replacement right)
  | MembershipCond (term, sort) ->
    MembershipCond (replace_term needle replacement term, sort)
  | BoolCond term -> BoolCond (replace_term needle replacement term)

let replace_capture_terms captures conditions =
  captures
  |> List.fold_left
       (fun conditions capture ->
         conditions
         |> List.map
              (replace_condition capture.Helper.call_term (Var capture.Helper.formal_var)))
       conditions

let filter_captures_by_call_vars used_vars captures =
  captures
  |> List.filter (fun capture ->
    Condition_closure.term_vars capture.Helper.call_term
    |> List.exists (fun var -> List.mem var used_vars))

type indexed_predicate_source =
  { index_source_id : string
  ; source_exp : exp
  ; source_term : term
  ; indexed_term : term
  }

let rec indexed_predicate_source missing_source component term =
  match component.it, term with
  | SubE (inner, _, _), _ | CvtE (inner, _, _), _ ->
    indexed_predicate_source missing_source inner term
  | IdxE (source_exp, index_exp), App ("index", [ source_term; _index_term ]) ->
    (match index_exp.it with
    | VarE index_id when index_id.it = missing_source ->
      Some { index_source_id = index_id.it; source_exp; source_term; indexed_term = term }
    | _ -> None)
  | _ -> None

let indexed_predicate_sources missing_source components terms =
  List.combine components terms
  |> List.filter_map (fun (component, term) ->
    indexed_predicate_source missing_source component term)

let indexed_predicate_candidates missing_sources escape_source_ids components terms =
  missing_sources
  |> List.filter (fun source_id -> not (List.mem source_id escape_source_ids))
  |> List.concat_map (fun source_id ->
    indexed_predicate_sources source_id components terms)
  |> List.sort_uniq (fun left right ->
    match String.compare left.index_source_id right.index_source_id with
    | 0 -> compare left.indexed_term right.indexed_term
    | order -> order)

let lower_indexed_predicate_exists
    ctx
    env
    ~bound_vars
    origin
    prem
    rel_id
    components
    terms
    guards
    diagnostics
    missing_sources
    escape_source_ids =
  let build indexed source_element_sort source_term =
    if
      not
        (vars_subset
           (Condition_closure.term_vars source_term)
           bound_vars)
    then
      None
    else
      let stem = helper_local_stem origin (source_echo_prem prem) in
      let helper_head_var =
        Naming.maude_var ~fallback:"HEAD" (stem ^ "-head")
      in
      let source_tail_var =
        Naming.maude_var ~fallback:"TAIL" (stem ^ "-tail")
      in
      let head_term = Var helper_head_var in
      let body_conditions =
        guards @ [ BoolCond (relation_call rel_id terms) ]
        |> List.map (replace_condition indexed.indexed_term head_term)
      in
      let body_used_vars =
        Condition_closure.external_vars_of_conditions
          [ helper_head_var ]
          body_conditions
      in
      let capture_ids =
        components
        |> List.concat_map source_and_note_free_var_ids
        |> List.filter (fun id -> id <> indexed.index_source_id)
        |> List.sort_uniq String.compare
      in
      let captures =
        capture_candidates env capture_ids
        |> make_captures stem
        |> filter_captures_by_call_vars body_used_vars
      in
      let body_conditions = replace_capture_terms captures body_conditions in
      let helper_bound = helper_head_var :: capture_vars captures in
      let body_external =
        Condition_closure.external_vars_of_conditions helper_bound body_conditions
      in
      if body_external <> [] then
        None
      else
        let helper_request =
          { Helper.kind =
              Helper.Iter_premise_exists_bool
                { source_shape =
                    { prem_source = source_echo_prem prem
                    ; indexed_source = source_echo_exp indexed.source_exp
                    ; source_typ_source =
                        Il.Print.string_of_typ indexed.source_exp.note
                    ; predicate_source = source_echo_prem prem
                    }
                ; index_source_id = indexed.index_source_id
                ; helper_head_var
                ; source_tail_var
                ; source_element_sort
                ; captures
                ; body_eq_conditions = body_conditions
                }
          ; reason = "finite indexed runtime-predicate existential over a source list"
          ; origin
          }
        in
        let helper_name = Helper.request (Context.helpers ctx) helper_request in
        let helper_call =
          app helper_name
            (source_term
             :: List.map (fun capture -> capture.Helper.call_term) captures)
        in
        Some
          (with_conditions
             env
             bound_vars
             [ BoolCond helper_call ]
             diagnostics)
  in
  match
    indexed_predicate_candidates
      missing_sources
      escape_source_ids
      components
      terms
  with
    | [ indexed ] ->
      (match flat_list_element_typ indexed.source_exp.note with
      | None -> None
      | Some source_element_typ ->
        (match Expr_translate.carrier_sort_of_typ source_element_typ with
        | None -> None
        | Some source_element_sort ->
          build indexed source_element_sort indexed.source_term))
    | _ -> None

let lower
    ctx
    env
    ~allow_runtime_search
    ~bound_vars
    ~blocked_witness_source_ids
    ~escape_source_ids
    ~future_prems
    origin
    prem
    rel_id
    exp
    relation_shape =
  match analyze_runtime_predicate_args ctx env ~bound_vars origin rel_id exp relation_shape with
  | Error reason ->
    unsupported_prem ctx env ~bound_vars origin "Premise/RulePr/runtime-predicate/arity" prem reason
  | Ok (Runtime_predicate_ready
          { guards
          ; predicate_term
          ; terms
          ; input_sorts
          ; bound_after_guards
          ; diagnostics
          ; _
          }) ->
    (match Runtime_predicate_search.truth_plan ctx rel_id.it with
    | Runtime_predicate_search.Truth_not_needed ->
      { (empty_with_env ~bound_vars:bound_after_guards env) with
        eq_conditions = guards @ [ BoolCond predicate_term ]
      ; diagnostics
      }
    | truth_plan when allow_runtime_search ->
      (match input_sorts with
      | Some input_sorts ->
        (match
           Runtime_predicate_search.truth_helper_request
             ~input_terms:terms
             ~input_sorts
             truth_plan
         with
        | Some request ->
          let helper_name =
            Helper.request
              (Context.helpers ctx)
              { Helper.kind = Helper.Runtime_predicate_truth_search request
              ; reason = Runtime_truth_search_helper.reason request
              ; origin
              }
          in
          { (empty_with_env ~bound_vars:bound_after_guards env) with
            eq_conditions = guards
          ; rule_conditions =
              [ Runtime_truth_search_helper.rewrite_condition ~helper_name request ]
          ; runtime_truth_search_requests = [ request ]
          ; diagnostics
          }
        | None ->
          let diagnostic =
            Runtime_predicate_search.truth_diagnostic ctx rel_id.it
          in
          let constructor, reason, suggestion =
            match diagnostic with
            | None ->
              ( "Premise/RulePr/runtime-predicate/truth-search-needed"
              , "runtime predicate needs a rewrite-backed truth-search helper, but no source-complete helper request could be built"
              , "Keep this predicate Unsupported until its source closure can be materialized as rewrite-backed helper rules"
              )
            | Some diagnostic ->
              ( diagnostic.Runtime_predicate_search.constructor
              , diagnostic.Runtime_predicate_search.reason
              , diagnostic.Runtime_predicate_search.suggestion
              )
          in
          runtime_predicate_unsupported
            ctx
            env
            ~bound_vars
            origin
            prem
            constructor
            diagnostics
            guards
            reason
            suggestion)
      | None ->
        runtime_predicate_unsupported
          ctx
          env
          ~bound_vars
          origin
          prem
          "Premise/RulePr/runtime-predicate/truth-search-sort"
          diagnostics
          guards
          "runtime predicate needs a rewrite-backed truth-search helper, but at least one argument type has no Maude carrier sort"
          "Keep this predicate Unsupported until the source relation component types can be mapped to helper argument sorts")
    | _ ->
      let diagnostic =
        Runtime_predicate_search.truth_diagnostic ctx rel_id.it
      in
      let constructor, reason, suggestion =
        match diagnostic with
        | None ->
          ( "Premise/RulePr/runtime-predicate/truth-search-in-ceq"
          , "runtime predicate needs a rewrite-backed truth-search helper, but this premise is being lowered in a pure equational context"
          , "Use this predicate only inside a crl/helper context, or add an explicit rewrite-dependent carrier before lowering it"
          )
        | Some diagnostic ->
          ( diagnostic.Runtime_predicate_search.constructor
          , diagnostic.Runtime_predicate_search.reason
          , diagnostic.Runtime_predicate_search.suggestion
          )
      in
      runtime_predicate_unsupported
        ctx
        env
        ~bound_vars
        origin
        prem
        constructor
        diagnostics
        guards
        reason
        suggestion)
  | Ok (Runtime_predicate_needs_binding
          { guards
          ; diagnostics
          ; components
          ; terms
          ; missing_sources
          ; reason
          ; suggestion
          }) ->
    (match
       lower_indexed_predicate_exists
         ctx
         env
         ~bound_vars
         origin
         prem
         rel_id
         components
         terms
         guards
         diagnostics
         missing_sources
         escape_source_ids
     with
    | Some result -> result
    | None ->
      if
        missing_sources <> []
        && List.for_all
             (fun id -> List.mem id blocked_witness_source_ids)
             missing_sources
      then
        runtime_predicate_blocked_by_prior_witness
          ctx
          env
          ~bound_vars
          origin
          prem
          diagnostics
          guards
          missing_sources
      else
      (match
         Runtime_predicate_search.local_existential_plan
           ctx
           rel_id.it
           ~missing_sources
           ~escape_source_ids
           ~future_prems
      with
      | Some plan when allow_runtime_search ->
        (match local_witness_arguments missing_sources components terms with
        | Some (input_terms, input_sorts, witness_index, witness_term, witness_sort) ->
          let guides =
            match missing_sources with
            | [ witness_source_id ] ->
              local_witness_guides
                ctx
                env
                ~bound_vars
                origin
                ~witness_source_id
                ~witness_term
                ~witness_sort
                future_prems
            | [] | _ :: _ :: _ -> []
          in
          (match
             Runtime_predicate_search.helper_request
               ~input_terms
               ~input_sorts
               ~guides
               ~witness_index
               ~witness_term
               ~witness_sort
               plan
           with
        | Some request ->
          let helper_name =
            Helper.request
              (Context.helpers ctx)
              { Helper.kind = Helper.Runtime_predicate_search request
              ; reason = Runtime_search_helper.reason request
              ; origin
              }
          in
          let witness_vars = Condition_closure.term_vars witness_term in
          { (empty_with_env ~bound_vars:(normalize_vars (bound_vars @ witness_vars)) env)
            with
            eq_conditions = guards
          ; rule_conditions =
              [ Runtime_search_helper.rewrite_condition ~helper_name request ]
          ; runtime_search_requests = [ request ]
          ; diagnostics
          }
        | None ->
          let diagnostic =
            Runtime_predicate_search.binding_diagnostic
              ctx
              rel_id.it
              ~missing_sources
              ~escape_source_ids
              ~future_prems
          in
          let constructor, reason, suggestion, blocked_witness_source_ids =
            match diagnostic with
            | None ->
              "Premise/RulePr/runtime-predicate/binding-needed", reason, suggestion, []
            | Some diagnostic ->
              ( diagnostic.Runtime_predicate_search.constructor
              , diagnostic.Runtime_predicate_search.reason
              , diagnostic.Runtime_predicate_search.suggestion
              , diagnostic.Runtime_predicate_search.blocked_witness_source_ids )
          in
          runtime_predicate_unsupported
            ~blocked_witness_source_ids
            ctx
            env
            ~bound_vars
            origin
            prem
            constructor
            diagnostics
            guards
            reason
            suggestion)
        | None ->
          runtime_predicate_unsupported
            ctx
            env
            ~bound_vars
            origin
            prem
            "Premise/RulePr/runtime-predicate/binding-needed"
            diagnostics
            guards
            reason
            "Runtime search currently requires exactly one direct VarE witness argument; keep this premise Unsupported until a source-derived helper can preserve the more complex witness pattern")
      | _ ->
        let diagnostic =
          Runtime_predicate_search.binding_diagnostic
            ctx
            rel_id.it
            ~missing_sources
            ~escape_source_ids
            ~future_prems
        in
        let constructor, reason, suggestion, blocked_witness_source_ids =
          match diagnostic with
          | None ->
            "Premise/RulePr/runtime-predicate/binding-needed", reason, suggestion, []
          | Some diagnostic ->
            ( diagnostic.Runtime_predicate_search.constructor
            , diagnostic.Runtime_predicate_search.reason
            , diagnostic.Runtime_predicate_search.suggestion
            , diagnostic.Runtime_predicate_search.blocked_witness_source_ids )
        in
        runtime_predicate_unsupported
          ~blocked_witness_source_ids
          ctx
          env
          ~bound_vars
          origin
          prem
          constructor
          diagnostics
          guards
          reason
          suggestion))
  | Ok (Runtime_predicate_bad_value { guards; diagnostics }) ->
    runtime_predicate_unsupported
      ctx
      env
      ~bound_vars
      origin
      prem
      "Premise/RulePr/runtime-predicate/value"
      diagnostics
      guards
      "runtime predicate premise arguments must lower as already-bound Maude values in this helper-free slice"
      "Keep this predicate premise Unsupported until a source-derived binding/complement helper is available"
