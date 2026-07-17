open Maude_ir
open Util.Source

type item =
  { name : string
  ; origin : Origin.t
  ; request : Runtime_search_helper.request
  }

type result =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

type rule_surface =
  { search_op : string
  ; hit_op : string
  ; extra_lhs_terms : Maude_ir.term list
  }

let generated name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let search_sort name =
  Maude_ir.sort ("RuntimeSearch" ^ Naming.sort_token name ^ "Conf")

let loop_op name =
  Naming.helper_companion ~role:"runtime-search-loop" name

let candidates_op name =
  Naming.helper_companion ~role:"runtime-search-candidates" name

let candidate_op name =
  Naming.helper_companion ~role:"runtime-search-candidate" name

let visited_key_op name =
  Naming.helper_companion ~role:"runtime-search-visited" name

let candidates_var_name name =
  "RSCANDS" ^ name

let visited_var_name name =
  "RSVIS" ^ name

let public_rule_surface item =
  { search_op = Runtime_search_helper.search_op ~helper_name:item.name
  ; hit_op = Runtime_search_helper.hit_op ~helper_name:item.name
  ; extra_lhs_terms = []
  }

let loop_rule_surface item =
  { search_op = loop_op item.name
  ; hit_op = Runtime_search_helper.hit_op ~helper_name:item.name
  ; extra_lhs_terms =
      [ Var (candidates_var_name item.name); Var (visited_var_name item.name) ]
  }

let frozen_all sorts =
  match sorts with
  | [] -> []
  | _ ->
    let rec range acc index = function
      | [] -> List.rev acc
      | _ :: rest -> range (index :: acc) (index + 1) rest
    in
    [ Maude_ir.Frozen (range [] 1 sorts) ]

let helper_surface item =
  Runtime_search_helper.surface
    ~helper_name:item.name ~origin:item.origin item.request

let finite_helper_surface item (_plan : Runtime_witness_domain.t) =
  let request = item.request in
  let result_sort = search_sort item.name in
  let spectec_terminal = Maude_ir.sort "SpectecTerminal" in
  let spectec_terminals = Maude_ir.sort "SpectecTerminals" in
  let public_search_op = Runtime_search_helper.search_op ~helper_name:item.name in
  let loop_search_op = loop_op item.name in
  let candidates_op = candidates_op item.name in
  let candidate_op = candidate_op item.name in
  let visited_key_op = visited_key_op item.name in
  let candidates_var = candidates_var_name item.name in
  let visited_var = visited_var_name item.name in
  let input_var index =
    Var ("RSIN" ^ item.name ^ string_of_int (index + 1))
  in
  let input_vars =
    request.input_sorts |> List.mapi (fun index _ -> input_var index)
  in
  let input_var_decls =
    request.input_sorts
    |> List.mapi (fun index sort ->
      generated
        item.name
        item.origin
        (Maude_ir.var
           ("RSIN" ^ item.name ^ string_of_int (index + 1))
           (Maude_ir.sort_ref sort)))
  in
  helper_surface item
  @ [ generated
        item.name
        item.origin
        (Maude_ir.op
           loop_search_op
           (List.map Maude_ir.sort_ref request.input_sorts
            @ [ Maude_ir.sort_ref spectec_terminals
              ; Maude_ir.sort_ref spectec_terminals
              ])
           result_sort
           ~attrs:(frozen_all (request.input_sorts @ [ spectec_terminals; spectec_terminals ])))
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           candidates_op
           (List.map Maude_ir.sort_ref request.input_sorts)
           spectec_terminals)
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           candidate_op
           [ Maude_ir.sort_ref spectec_terminal ]
           spectec_terminal
           ~attrs:[ Maude_ir.Ctor ])
    ; generated
        item.name
        item.origin
        (Maude_ir.op
           visited_key_op
           (List.map Maude_ir.sort_ref request.input_sorts)
           spectec_terminal
           ~attrs:[ Maude_ir.Ctor ])
    ; generated
        item.name
        item.origin
        (Maude_ir.var candidates_var (Maude_ir.sort_ref spectec_terminals))
    ; generated
        item.name
        item.origin
        (Maude_ir.var visited_var (Maude_ir.sort_ref spectec_terminals))
    ]
  @ input_var_decls
  @ [ generated
        item.name
        item.origin
        (Maude_ir.crl
           ~label:(item.name ^ "-finite-entry")
           (App (public_search_op, input_vars))
           (App (loop_search_op, input_vars @ [ Var candidates_var; Const "eps" ]))
           [ EqCondition
               (MatchCond (Var candidates_var, App (candidates_op, input_vars)))
           ])
    ]

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
    ~source_echo:(Runtime_search_helper.reason item.request)
    ()

let blocked_diagnostic ctx item =
  diagnostic
    ctx
    item
    item.origin
    "RuntimeSearch/materializer-unimplemented"
    ("runtime predicate search request is proven enough to request a helper, but the source-complete crl materializer is not implemented yet: "
     ^ Runtime_search_helper.reason item.request)
    "Emit no runtime-search helper surface until every source RuleD in the search closure can be materialized as Maude crl rules"

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

let lower_patterns ctx origin exps =
  let source_names =
    exps
    |> List.concat_map (fun exp ->
      Il.Free.(free_exp exp).varid |> Il.Free.Set.elements)
    |> List.sort_uniq String.compare
  in
  let names = Local_name.reserve_sources Local_name.empty source_names in
  let rec loop names env terms guards bindings diagnostics = function
    | [] ->
      Some (List.rev terms),
      env,
      List.rev guards,
      List.rev bindings,
      List.rev diagnostics,
      names
    | exp :: exps ->
      let exp_origin =
        child_origin
          origin
          (Printf.sprintf "head[%d]" (List.length terms + 1))
          "RuntimeSearch/Head"
          exp.at
          (Some (Il.Print.string_of_exp exp))
      in
      let result, names =
        Expr_translate.lower_pattern_with_bindings_named names ctx env exp_origin exp
      in
      let env =
        List.fold_left add_binding env result.introduced_bindings
      in
      match result.pattern_term with
      | Some term ->
        loop names
          env
          (term :: terms)
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.introduced_bindings bindings)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps
      | None ->
        loop names
          env
          terms
          (List.rev_append result.pattern_guards guards)
          (List.rev_append result.introduced_bindings bindings)
          (List.rev_append result.pattern_diagnostics diagnostics)
          exps
  in
  loop names Expr_env.empty [] [] [] [] exps

let split_witness index components =
  let rec loop n left = function
    | [] -> None
    | component :: right when n = 0 -> Some (List.rev left, component, right)
    | component :: rest -> loop (n - 1) (component :: left) rest
  in
  loop index [] components

let rule_label item (rule : Analysis.Function_graph.runtime_search_rule) index =
  let rule_id = Option.value ~default:("rule-" ^ string_of_int index) rule.rule_id in
  Some (Maude_ir.sanitize_label (item.name ^ "-" ^ rule.relation_id ^ "-" ^ rule_id))

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
  if not (String.equal rule.relation_id request.rel_id) then
    Error
      [ unsupported
          ctx
          item
          origin
          "RuntimeSearch/materializer/relation-local-interface"
          ("runtime search closure contains dependent relation `"
           ^ rule.relation_id
           ^ "`, but this materializer slice only emits source rules for the requested relation `"
           ^ request.rel_id
           ^ "`")
          "Add relation-local search interfaces before materializing closure dependencies; do not inline another relation by name"
      ]
  else
    let expected_count = List.length request.input_sorts + 1 in
    match Analysis.Relation_graph.exp_components_for_count expected_count rule.head with
    | None ->
      Error
        [ unsupported
            ctx
            item
            origin
            "RuntimeSearch/materializer/head-arity"
            (Printf.sprintf
               "source RuleD head does not match the requested relation arity %d without flattening"
               expected_count)
            "Preserve the source relation component structure before emitting a runtime-search rule"
        ]
    | Some components ->
      (match split_witness request.witness_index components with
      | None ->
        Error
          [ unsupported
              ctx
              item
              origin
              "RuntimeSearch/materializer/witness-index"
              "runtime-search request witness index is outside the source RuleD component list"
              "Keep the request Unsupported until witness position is derived from the IL RulePr component structure"
          ]
      | Some (left, witness_exp, right) ->
        let input_exps = left @ right in
        let pattern_exps = input_exps @ [ witness_exp ] in
        let terms_opt, env, head_guards, _bindings, head_diags, names =
          lower_patterns ctx origin pattern_exps
        in
        match terms_opt with
        | None -> Error head_diags
        | Some terms ->
          let input_count = List.length input_exps in
          let input_terms, witness_terms =
            let rec take n left right =
              if n = 0 then List.rev left, right
              else
                match right with
                | [] -> List.rev left, []
                | term :: rest -> take (n - 1) (term :: left) rest
            in
            take input_count [] terms
          in
          (match witness_terms with
          | [ witness_term ] ->
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
            | Deferred (_, diagnostics) -> Error (head_diags @ diagnostics)
            | Complete premise_result ->
            let diagnostics =
              head_diags @ Premise_result.diagnostics premise_result
            in
            if Premise_result.has_else premise_result then
              Error
                (diagnostics
                 @ [ unsupported
                       ctx
                       item
                       origin
                       "RuntimeSearch/materializer/ElsePr"
                       "runtime-search helper rule contains ElsePr, which needs a source-derived enabledness complement"
                       "Keep this search helper Unsupported until otherwise complement lowering exists for this source shape"
                   ])
            else if Premise_result.runtime_search_requests premise_result <> [] then
              Error
                (diagnostics
                 @ [ unsupported
                       ctx
                       item
                       origin
                       "RuntimeSearch/materializer/nested-search"
                       "runtime-search helper rule would need another local-existential search helper"
                       "Add relation-local search interfaces before nesting runtime-search helpers"
                   ])
            else if List.exists Diagnostics.is_fatal diagnostics then
              Error diagnostics
            else
              let lhs = App (surface.search_op, input_terms @ surface.extra_lhs_terms) in
              let rhs =
                App (surface.hit_op, [ witness_term ])
              in
              let conditions =
                List.map (fun condition -> EqCondition condition) head_guards
                @ Premise_result.rule_conditions premise_result
                @ List.map
                    (fun condition -> EqCondition condition)
                    (Premise_result.eq_conditions premise_result)
                |> Condition_closure.normalize_rule_conditions
                     ~constructor_op:
                       (Condition_closure.source_constructor_certificate ctx)
                     [ lhs ]
                |> dedup_rule_conditions
              in
              let admissibility_diags =
                Condition_admissibility.crl_admissibility_diagnostics ctx origin lhs rhs conditions
              in
              if List.exists Diagnostics.is_fatal admissibility_diags then
                Error (diagnostics @ admissibility_diags)
              else
                Ok
                  (generated
                     item.name
                     origin
                     (crl ?label:(rule_label item rule index) lhs rhs conditions)))
          | _ ->
            Error
              [ unsupported
                  ctx
                  item
                  origin
                  "RuntimeSearch/materializer/witness-shape"
                  "runtime-search witness component did not lower to exactly one Maude pattern term"
                  "Keep this helper Unsupported until the source witness component has a single carrier pattern"
              ]))

let lower_rule ctx item index rule =
  lower_rule_with_surface ctx item (public_rule_surface item) index rule

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
      | Ok statement -> loop (index + 1) (statement :: statements) diagnostics rules
      | Error new_diagnostics ->
        loop (index + 1) statements (diagnostics @ new_diagnostics) rules)
  in
  loop 1 [] [] rules

let contains_source_premise source_premise prems =
  let source = Il.Print.string_of_prem source_premise in
  prems
  |> List.exists (fun prem ->
    String.equal source (Il.Print.string_of_prem prem))

let is_target_guided_source_rule
    (target : Runtime_witness_proof.target_chain)
    (rule : Analysis.Function_graph.runtime_search_rule)
  =
  contains_source_premise target.recursive_premise rule.prems
  && contains_source_premise target.target_premise rule.prems

let lower_acyclic_item ctx item =
  let local_rules = local_rules item in
  let rec loop index statements diagnostics = function
    | [] ->
      if List.exists Diagnostics.is_fatal diagnostics then
        { statements = []; diagnostics }
      else
        { statements = helper_surface item @ List.rev statements; diagnostics }
    | rule :: rules ->
      (match lower_rule ctx item index rule with
      | Ok statement -> loop (index + 1) (statement :: statements) diagnostics rules
      | Error new_diagnostics ->
        loop (index + 1) statements (diagnostics @ new_diagnostics) rules)
  in
  match local_rules with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeSearch/materializer/no-local-rules"
            ("runtime search closure for `"
             ^ item.request.rel_id
             ^ "` has no source RuleD clauses for that relation")
            "Keep this helper Unsupported until the referenced relation body is available in the source index"
        ]
    }
  | _ -> loop 1 [] [] local_rules

let lower_finite_transitive_item ctx item domain =
  match Runtime_witness_domain.prepare domain with
  | Error blockers ->
    let reason =
      blockers
      |> List.map (fun blocker -> blocker.Runtime_witness_domain.reason)
      |> String.concat "; "
    in
    let suggestion =
      blockers
      |> List.map (fun blocker -> blocker.Runtime_witness_domain.suggestion)
      |> String.concat "; "
    in
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeSearch/materializer/finite-domain-blocked"
            reason
            suggestion
        ]
    }
  | Ok plan ->
    let local_rules = local_rules item in
    let local_result =
      match local_rules with
      | [] ->
        { statements = []
        ; diagnostics =
            [ unsupported
                ctx
                item
                item.origin
                "RuntimeSearch/materializer/finite-transitive/no-local-rules"
                ("finite-transitive runtime-search helper for `"
                 ^ item.request.rel_id
                 ^ "` has no source RuleD clauses to materialize")
                "Keep this helper Unsupported until the referenced relation body is available in the source index"
            ]
        }
      | _ ->
        lower_rules_with_surface
          ctx
          item
          (loop_rule_surface item)
          (finite_helper_surface item plan)
          local_rules
    in
    if List.exists Diagnostics.is_fatal local_result.diagnostics then
      local_result
    else
      { statements = []
      ; diagnostics =
          local_result.diagnostics
          @ [ unsupported
                ctx
                item
                item.origin
                "RuntimeSearch/materializer/finite-domain-candidates-unimplemented"
                ("runtime-search helper has source finite-domain metadata ("
                 ^ Runtime_witness_domain.describe plan
                 ^ "), and its source rules lower against an internal loop surface, but the source-domain candidate list equations are not implemented yet. Required candidate sources: "
                 ^ Runtime_witness_domain.describe_candidate_sources plan)
                "Materialize runtimeSearchCandidates from the finite domain premise before emitting this helper; do not emit partial witness-search rules"
            ]
      }

let lower_target_guided_item ctx item target =
  let seed_rules =
    local_rules item
    |> List.filter (fun rule -> not (is_target_guided_source_rule target rule))
  in
  match seed_rules with
  | [] ->
    { statements = []
    ; diagnostics =
        [ unsupported
            ctx
            item
            item.origin
            "RuntimeSearch/materializer/target-guided/no-seed-rules"
            "target-guided runtime-search helper has no non-recursive source RuleD clauses to generate witness seeds"
            "Keep this helper Unsupported until the source relation exposes base witness-producing rules"
        ]
    }
  | _ ->
    lower_rules_with_surface
      ctx
      item
      (public_rule_surface item)
      (helper_surface item)
      seed_rules

let materialize_item ctx item =
  match Runtime_witness_space.proof item.request.witness_space |> Runtime_witness_proof.recursion with
  | Runtime_witness_proof.Acyclic -> lower_acyclic_item ctx item
  | Runtime_witness_proof.Finite_transitive domain ->
    lower_finite_transitive_item ctx item domain
  | Runtime_witness_proof.Target_guided_self target ->
    lower_target_guided_item ctx item target

let materialize ctx items =
  let results =
    items
    |> List.map (fun item ->
      match materialize_item ctx item with
      | { statements = []; diagnostics = [] } ->
        { statements = []; diagnostics = [ blocked_diagnostic ctx item ] }
      | result -> result)
  in
  { statements = List.concat_map (fun result -> result.statements) results
  ; diagnostics = List.concat_map (fun result -> result.diagnostics) results
  }
