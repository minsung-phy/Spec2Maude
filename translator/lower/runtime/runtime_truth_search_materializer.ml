open Maude_ir
open Il.Ast
open Util.Source

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_truth_search_helper.request
  }

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type rule_surface =
  { search_op : string
  ; ok_op : string
  ; extra_lhs_terms : Maude_ir.term list
  }

type indexed_head =
  { source_exp : exp
  ; target_term : Maude_ir.term
  ; index_source_id : string
  ; indexed_origin : Origin.t
  }

let generated name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let public_rule_surface item =
  { search_op = Runtime_truth_search_helper.search_op ~helper_name:item.name
  ; ok_op = Runtime_truth_search_helper.ok_op ~helper_name:item.name
  ; extra_lhs_terms = []
  }

let helper_surface item =
  Runtime_truth_search_helper.surface
    ~helper_name:item.name ~origin:item.origin item.request

let diagnostic ctx item origin constructor reason suggestion =
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin
    ~constructor
    ~enclosing:
      (Diagnostic_provenance.enclosing
         ~context:(Context.enclosing_path ctx) origin)
    ~profile:(Context.profile_name ctx)
    ~reason
    ~suggestion
    ~source_echo:(Runtime_truth_search_helper.reason item.request)
    ()

let unsupported ctx item origin constructor reason suggestion =
  diagnostic ctx item origin constructor reason suggestion

let child_origin parent segment ast_constructor region source_echo =
  Origin.with_child ?source_echo parent segment ~ast_constructor region

let rule_origin parent index (rule : Analysis.Function_graph.runtime_search_rule) =
  child_origin
    parent
    (Printf.sprintf "RuleD[%d]" index)
    "RuleD"
    rule.origin.region
    rule.source_echo

let add_binding env (id, (binding : Expr_env.binding)) =
  Expr_env.add env id binding

let typ_is_iter = Type_shape.typ_is_iter

let flat_list_element_typ typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let rec indexed_head_source exp =
  match exp.it with
  | SubE (inner, _, _) | CvtE (inner, _, _) ->
    indexed_head_source inner
  | IdxE (source_exp, index_exp) ->
    (match index_exp.it with
    | VarE index_id -> Some (index_id.it, source_exp)
    | _ -> None)
  | _ -> None

let typecheck_for_indexed_head ctx env origin exp target target_sort =
  let witness =
    Expr_translate.lower_type_witness
      ctx
      env
      origin
      ~constructor:"RuntimeTruthSearch/head-indexed"
      exp.note
  in
  match witness.term with
  | None -> [], witness.diagnostics
  | Some witness_term ->
    ( witness.guards
      @ Expr_translate.typecheck_conditions_for_typ
          exp.note
          target_sort
          target
          witness_term
    , witness.diagnostics )

let lower_indexed_head names ctx env origin exp =
  match indexed_head_source exp, Expr_translate.carrier_sort_of_typ exp.note with
  | Some (index_source_id, source_exp), Some target_sort ->
    let target_term, names =
      Local_name.fresh_qualified
        names Local_name.Head (sort_ref target_sort)
    in
    let guards, diagnostics =
      typecheck_for_indexed_head ctx env origin exp target_term target_sort
    in
    Some
        ( names
      , target_term
      , { source_exp
        ; target_term
        ; index_source_id
        ; indexed_origin = origin
        }
      , guards
      , diagnostics )
  | _ -> None

let lower_patterns ctx env origin exps =
  let source_names =
    exps
    |> List.concat_map (fun exp ->
      Il.Free.(free_exp exp).varid |> Il.Free.Set.elements)
    |> List.sort_uniq String.compare
  in
  let names = Local_name.reserve_sources Local_name.empty source_names in
  let names =
    Local_name.reserve_existing_many names (Expr_env.bound_vars env)
  in
  let rec loop names env terms indexed_heads guards diagnostics = function
    | [] ->
      ( Some (List.rev terms)
      , env
      , List.rev indexed_heads
      , List.rev guards
      , List.rev diagnostics
      , names )
    | exp :: exps ->
      let position = List.length terms + 1 in
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "head[%d]" position)
          "RuntimeTruthSearch/Head"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      match lower_indexed_head names ctx env exp_origin exp with
      | Some (names, term, indexed_head, new_guards, new_diagnostics) ->
        loop names
          env
          (term :: terms)
          (indexed_head :: indexed_heads)
          (List.rev_append new_guards guards)
          (List.rev_append new_diagnostics diagnostics)
          exps
      | None ->
        let result, names =
          Expr_translate.lower_pattern_with_bindings_named names ctx env exp_origin exp
        in
        let env =
          List.fold_left add_binding env result.introduced_bindings
        in
        (match result.pattern_term with
      | Some term ->
        loop names
          env
          (term :: terms)
          indexed_heads
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps
      | None ->
        loop names
          env
          terms
          indexed_heads
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps)
  in
  loop names env [] [] [] [] exps

let specialize_closed_inputs env components terms sorts =
  let rec loop env components terms sorts =
    match components, terms, sorts with
    | component :: components, term :: terms, sort :: sorts ->
      let env =
        match component.it with
        | VarE id when Condition_closure.term_vars term = [] ->
          Expr_env.add env id.it
            { Expr_env.term = term; sort; typ = component.note }
        | _ -> env
      in
      loop env components terms sorts
    | _, _, _ -> env
  in
  loop env components terms sorts

let vars_subset vars bound =
  List.for_all (fun var -> List.mem var bound) vars

let lower_indexed_head_unsupported ctx item indexed constructor reason suggestion =
  [ unsupported ctx item indexed.indexed_origin constructor reason suggestion ]

let lower_indexed_head_contains ctx item premise_result indexed =
  match flat_list_element_typ indexed.source_exp.note with
  | None ->
    [], lower_indexed_head_unsupported
          ctx
          item
          indexed
          "RuntimeTruthSearch/head-indexed/source-shape"
          "indexed relation-head target comes from a source expression that is not a flat list"
          "Keep this truth helper Unsupported until the indexed-head source can be lowered as a flat sequence membership"
  | Some _ ->
    let env =
      Expr_env.with_condition_bound_vars
        (Premise_result.env_after premise_result)
        (Premise_result.bound_vars_after premise_result)
    in
    let source_result =
      Expr_translate.lower_sequence ctx env indexed.indexed_origin indexed.source_exp
    in
    (match source_result.term with
    | None ->
      [], source_result.diagnostics
          @ lower_indexed_head_unsupported
              ctx
              item
              indexed
              "RuntimeTruthSearch/head-indexed/source-lowering"
              "indexed relation-head source list could not be lowered after the source premises"
              "Do not silently drop the indexed-head membership; keep the helper Unsupported"
    | Some source_term ->
      let bound_after_source =
        Condition_closure.conditions_admissible_bound
          ~constructor_op:(Condition_closure.source_constructor_certificate ctx)
          (Premise_result.bound_vars_after premise_result)
          source_result.guards
      in
      (match bound_after_source with
      | None ->
        [], source_result.diagnostics
            @ lower_indexed_head_unsupported
                ctx
                item
                indexed
                "RuntimeTruthSearch/head-indexed/source-admissibility"
                "indexed relation-head source list needs variables that are not bound before its guards"
                "Keep this helper Unsupported until the source premise order binds the indexed source sequence"
      | Some bound_after_source
        when not
               (vars_subset
                  (Condition_closure.term_vars source_term)
                  bound_after_source) ->
        [], source_result.diagnostics
            @ lower_indexed_head_unsupported
                ctx
                item
                indexed
                "RuntimeTruthSearch/head-indexed/source-vars"
                "indexed relation-head source list still contains variables that are not bound after source guards"
                "Keep this helper Unsupported until all variables used by the indexed source sequence are bound"
      | Some _ ->
        ( source_result.guards
          @ [ BoolCond (App ("contains", [ indexed.target_term; source_term ])) ]
        , source_result.diagnostics )))

let lower_indexed_head_conditions ctx item premise_result indexed_heads =
  indexed_heads
  |> List.fold_left
       (fun (conditions, diagnostics) indexed ->
         let new_conditions, new_diagnostics =
           lower_indexed_head_contains ctx item premise_result indexed
         in
         conditions @ new_conditions, diagnostics @ new_diagnostics)
       ([], [])

let rule_label item (rule : Analysis.Function_graph.runtime_search_rule) index =
  let rule_id =
    Option.value ~default:("rule-" ^ string_of_int index) rule.rule_id
  in
  Some
    (Maude_ir.sanitize_label
       (item.name ^ "-" ^ rule.relation_id ^ "-" ^ rule_id))

let dedup_rule_conditions conditions =
  List.fold_right
    (fun condition acc ->
      if List.exists (( = ) condition) acc then acc else condition :: acc)
    conditions
    []

let lower_rule_with_surface
    ctx
    item
    surface
    index
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  let request = item.request in
  let origin = rule_origin item.origin index rule in
  let ctx =
    Context.with_def ctx rule.relation_id
    |> fun ctx ->
    match rule.rule_id with
    | Some rule_id -> Context.with_rule ctx rule_id
    | None -> ctx
  in
  if not (String.equal rule.relation_id request.rel_id) then
    Error
      [ unsupported
          ctx
          item
          origin
          "RuntimeTruthSearch/materializer/relation-local-interface"
          ("runtime truth-search closure contains dependent relation `"
           ^ rule.relation_id
           ^ "`, but this materializer slice only emits source rules for the requested relation `"
           ^ request.rel_id
           ^ "`")
          "Add relation-local truth/search interfaces before materializing closure dependencies; do not inline another relation by name"
      ]
  else
    let names =
      Reld_rule_lowering.local_names_for_rule_parts
        rule.binds rule.head rule.prems
    in
    let bind_env, bind_statements, bind_diags, _names =
      Reld_rule_lowering.translate_rule_binds
        ctx origin names rule.binds
    in
    match
      Analysis.Relation_graph.exp_components_for_count
        (List.length request.input_sorts)
        rule.head
    with
    | None ->
      Error
        [ unsupported
            ctx
            item
            origin
            "RuntimeTruthSearch/materializer/head-arity"
            "source RuleD head does not match the requested relation arity without flattening"
            "Preserve the source relation component structure before emitting a runtime truth-search rule"
        ]
    | Some components ->
      let pattern_env =
        specialize_closed_inputs
          bind_env components request.input_terms request.input_sorts
      in
      let terms_opt, env, indexed_heads, head_guards, head_diags, names =
        lower_patterns ctx pattern_env origin components
      in
      (match terms_opt with
      | None -> Error (bind_diags @ head_diags)
      | Some input_terms ->
        let premise_translation, _names =
          Premise_translate.translate_premises_named
            names
            ~allow_runtime_search:true
            ~discharge_static_validation:false
            ctx
            env
            ~bound_conditions:head_guards
            ~escape_source_ids:[]
            ~bound_terms:input_terms
            origin
            rule.prems
        in
        (match premise_translation with
        | Premise_result.Blocked diagnostics
        | Deferred (_, diagnostics) -> Error (bind_diags @ head_diags @ diagnostics)
        | Complete premise_result ->
        let indexed_conditions, indexed_diags =
          lower_indexed_head_conditions ctx item premise_result indexed_heads
        in
        let diagnostics =
          bind_diags @ head_diags @ Premise_result.diagnostics premise_result
          @ indexed_diags
        in
        if Premise_result.has_else premise_result then
          Error
            (diagnostics
             @ [ unsupported
                   ctx
                   item
                   origin
                   "RuntimeTruthSearch/materializer/ElsePr"
                   "runtime truth-search helper rule contains ElsePr, which needs a source-derived enabledness complement"
                   "Keep this truth helper Unsupported until otherwise complement lowering exists for this source shape"
               ])
        else if List.exists Diagnostics.is_fatal diagnostics then
          Error diagnostics
        else
          let lhs =
            App (surface.search_op, input_terms @ surface.extra_lhs_terms)
          in
          let rhs = Const surface.ok_op in
          let conditions =
            List.map (fun condition -> EqCondition condition) head_guards
            @ Premise_result.rule_conditions premise_result
            @ List.map
                (fun condition -> EqCondition condition)
                (Premise_result.eq_conditions premise_result
                 @ indexed_conditions)
            |> Condition_closure.normalize_rule_conditions [ lhs ]
                 ~constructor_op:
                   (Condition_closure.source_constructor_certificate ctx)
            |> dedup_rule_conditions
          in
          let admissibility_diags =
            Condition_closure.crl_admissibility_diagnostics
              ctx
              origin
              lhs
              rhs
              conditions
          in
          if List.exists Diagnostics.is_fatal admissibility_diags then
            Error (diagnostics @ admissibility_diags)
          else
            Ok
              (bind_statements
               @ [ generated
                     item.name
                     origin
                     (crl ?label:(rule_label item rule index) lhs rhs conditions)
                 ])))

let local_rules item =
  item.request.rules
  |> List.filter (fun rule ->
    String.equal rule.Analysis.Function_graph.relation_id item.request.rel_id)

let lower_rules_with_surface ctx item surface surface_statements rules =
  let rec loop index statements diagnostics = function
    | [] ->
      if List.exists Diagnostics.is_fatal diagnostics then
        { statements = []; diagnostics }
      else
        { statements = surface_statements @ List.rev statements; diagnostics }
    | rule :: rules ->
      (match lower_rule_with_surface ctx item surface index rule with
      | Ok new_statements ->
        loop
          (index + 1)
          (List.rev_append new_statements statements)
          diagnostics
          rules
      | Error new_diagnostics ->
        loop (index + 1) statements (diagnostics @ new_diagnostics) rules)
  in
  loop 1 [] [] rules

let lower_acyclic_item ctx item =
  let local_rules = local_rules item in
  match local_rules with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeTruthSearch/materializer/no-local-rules"
            ("runtime truth-search closure for `"
             ^ item.request.rel_id
             ^ "` has no source RuleD clauses for that relation")
            "Keep this helper Unsupported until the referenced relation body is available in the source index"
        ]
    }
  | _ ->
    lower_rules_with_surface
      ctx
      item
      (public_rule_surface item)
      (helper_surface item)
      local_rules

let materialize_item ctx item =
  match item.request.recursion with
  | Runtime_truth_search_helper.Acyclic -> lower_acyclic_item ctx item
  | (Runtime_truth_search_helper.Finite_transitive _
    | Runtime_truth_search_helper.Target_guided_self _
    | Runtime_truth_search_helper.Recursive _) as recursion ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeTruthSearch/materializer/recursive-unimplemented"
            ("runtime truth-search request is recursive/transitive and is exclusively owned by the SCC worklist engine"
             ^ (match recursion with
                | Runtime_truth_search_helper.Recursive cycle ->
                  "; cycle: `" ^ String.concat " -> " cycle ^ "`"
                | Finite_transitive _ | Target_guided_self _ -> ""
                | Acyclic -> assert false))
            "Route this request through Runtime_truth_scc; the legacy truth-search engine accepts only acyclic request shapes"
        ]
    }

let materialize ctx items =
  let results = List.map (materialize_item ctx) items in
  { statements = List.concat_map (fun result -> result.statements) results
  ; diagnostics = List.concat_map (fun result -> result.diagnostics) results
  }
