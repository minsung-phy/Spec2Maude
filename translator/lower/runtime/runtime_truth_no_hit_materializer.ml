open Maude_ir

module Request = Helper_request

module Rule_components = Runtime_truth_rule_components
module Surface = Runtime_truth_no_hit_surface
module Indexed = Runtime_truth_indexed_refutation

open Surface

type result =
  | Complete of complete
  | Blocked of Diagnostics.t list

and complete =
  { statements : Maude_ir.generated list
  ; conditions : Maude_ir.rule_condition list
  ; diagnostics : Diagnostics.t list
  }

let complete_statements result = result.statements
let complete_conditions result = result.conditions
let complete_diagnostics result = result.diagnostics

type refuter_rules =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  ; complete : bool
  ; blockers : blocker list
  }

and blocker =
  { origin : Origin.t
  ; constructor : string
  ; ast_constructor : string
  ; relation_id : string
  ; rule_id : string option
  ; premise_index : int option
  ; premise_context : string option
  ; reason : string
  ; suggestion : string
  ; source_echo : string option
  }

let local_rules = Rule_components.local_rules

let specialized_input_terms request =
  let truth = request.Runtime_truth_decision_helper.truth_request in
  let names =
    Local_name.reserve_existing_many Local_name.empty
      (List.concat_map Condition_closure.term_vars truth.input_terms)
  in
  List.fold_left2
    (fun (terms, names) requested sort ->
      if Condition_closure.term_vars requested = [] then
        requested :: terms, names
      else
        let variable, names =
          Local_name.fresh_qualified names Local_name.Component (sort_ref sort)
        in
        variable :: terms, names)
    ([], names) truth.input_terms truth.input_sorts
  |> fun (terms, names) -> List.rev terms, names

let specialized_head_env request components =
  let truth = request.Runtime_truth_decision_helper.truth_request in
  let rec loop env components terms sorts =
    match components, terms, sorts with
    | (component : Il.Ast.exp) :: components, term :: terms, sort :: sorts ->
      let env =
        match component.it with
        | Il.Ast.VarE id when Condition_closure.term_vars term = [] ->
          Expr_env.add env id.it
            { Expr_env.term = term; sort; typ = component.note }
        | _ -> env
      in
      loop env components terms sorts
    | _, _, _ -> env
  in
  loop Expr_env.empty components truth.input_terms truth.input_sorts

let complete statements diagnostics =
  { statements; diagnostics; complete = true; blockers = [] }

let incomplete ?(diagnostics = []) blocker =
  { statements = []
  ; diagnostics
  ; complete = false
  ; blockers = [ blocker ]
  }

let exp_constructor (exp : Il.Ast.exp) =
  match exp.it with
  | Il.Ast.VarE _ -> "VarE"
  | Il.Ast.BoolE _ -> "BoolE"
  | Il.Ast.NumE _ -> "NumE"
  | Il.Ast.TextE _ -> "TextE"
  | Il.Ast.UnE _ -> "UnE"
  | Il.Ast.BinE _ -> "BinE"
  | Il.Ast.CmpE _ -> "CmpE"
  | Il.Ast.IdxE _ -> "IdxE"
  | Il.Ast.SliceE _ -> "SliceE"
  | Il.Ast.UpdE _ -> "UpdE"
  | Il.Ast.ExtE _ -> "ExtE"
  | Il.Ast.StrE _ -> "StrE"
  | Il.Ast.DotE _ -> "DotE"
  | Il.Ast.CompE _ -> "CompE"
  | Il.Ast.LenE _ -> "LenE"
  | Il.Ast.TupE _ -> "TupE"
  | Il.Ast.CallE _ -> "CallE"
  | Il.Ast.IterE _ -> "IterE"
  | Il.Ast.OptE _ -> "OptE"
  | Il.Ast.ListE _ -> "ListE"
  | Il.Ast.CatE _ -> "CatE"
  | Il.Ast.MemE _ -> "MemE"
  | Il.Ast.LiftE _ -> "LiftE"
  | Il.Ast.CaseE _ -> "CaseE"
  | Il.Ast.UncaseE _ -> "UncaseE"
  | Il.Ast.TheE _ -> "TheE"
  | Il.Ast.ProjE _ -> "ProjE"
  | Il.Ast.IfE _ -> "IfE"
  | Il.Ast.CvtE _ -> "CvtE"
  | Il.Ast.SubE _ -> "SubE"

let premise_constructor (prem : Il.Ast.prem) =
  match prem.it with
  | Il.Ast.RulePr _ -> "RulePr"
  | Il.Ast.IfPr _ -> "IfPr"
  | Il.Ast.LetPr _ -> "LetPr"
  | Il.Ast.ElsePr -> "ElsePr"
  | Il.Ast.IterPr _ -> "IterPr"
  | Il.Ast.NegPr _ -> "NegPr"

let blocker
    ?rule
    ?premise_index
    ?premise
    ~request
    ~origin
    ~constructor
    ~ast_constructor
    ~reason
    ~suggestion
    () =
  let truth = request.Runtime_truth_decision_helper.truth_request in
  let rule_id, rule_echo =
    match rule with
    | None -> None, None
    | Some (rule : Analysis.Function_graph.runtime_search_rule) ->
      rule.rule_id, rule.source_echo
  in
  { origin
  ; constructor
  ; ast_constructor
  ; relation_id = truth.rel_id
  ; rule_id
  ; premise_index
  ; premise_context = Option.map Il.Print.string_of_prem premise
  ; reason
  ; suggestion
  ; source_echo =
      (match premise with
      | Some prem -> Some (Il.Print.string_of_prem prem)
      | None ->
        (match rule_echo with
        | Some _ as source_echo -> source_echo
        | None -> Some (Runtime_truth_decision_helper.reason request)))
  }

let no_hit_blocker
    ?rule ?premise_index ?premise request origin constructor ast_constructor reason =
  blocker
    ?rule
    ?premise_index
    ?premise
    ~request
    ~origin
    ~constructor
    ~ast_constructor
    ~reason
    ~suggestion:
      "Keep runtime false blocked until this source rule has a complete structural refutation"
    ()

let append_refuters left right =
  { statements = left.statements @ right.statements
  ; diagnostics = left.diagnostics @ right.diagnostics
  ; complete = left.complete && right.complete
  ; blockers = left.blockers @ right.blockers
  }

let rec is_closed_pattern = function
  | Var _ -> false
  | Const _ | Qid _ -> true
  | App (_constructor, args) -> List.for_all is_closed_pattern args

let rec nth_opt items index =
  match items, index with
  | item :: _, 0 -> Some item
  | _ :: rest, index when index > 0 -> nth_opt rest (index - 1)
  | _ -> None

let option_all items =
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | Some item :: rest -> loop (item :: acc) rest
    | None :: _ -> None
  in
  loop [] items

type pattern_refutation =
  | Pattern_irrefutable
  | Pattern_refutable of term
  | Pattern_refutation_unsupported of string

let expected_from_pattern = function
  | Var _ -> Pattern_irrefutable
  | Const _ as term -> Pattern_refutable term
  | Qid _ as term -> Pattern_refutable term
  | App (_constructor, _args) as term when is_closed_pattern term ->
    Pattern_refutable term
  | App _ ->
    Pattern_refutation_unsupported
      "open constructor mismatch requires a closed constructor-family proof"

type open_head_refutation =
  | Irrefutable
  | Refutable of Maude_ir.generated list
  | Refutation_unsupported of string

let constructor_family ctx typ =
  let env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
  match Static_key.typ_ref ~env typ with
  | None -> None
  | Some reference ->
    Some
      ( Naming.source_owner reference.Static_key.category_id
      , reference.static_args_key )

let replace_nth index replacement terms =
  terms
  |> List.mapi (fun current term -> if current = index then replacement else term)

let open_head_refutation
    ctx helper_name origin refuter input_terms components pattern_terms =
  let rec loop index statements = function
    | [], [] ->
      if statements = [] then Irrefutable else Refutable (List.rev statements)
    | (component : Il.Ast.exp) :: components,
      (App (constructor_op, args) as pattern) :: patterns
      when not (is_closed_pattern pattern) ->
      (match constructor_family ctx component.note with
      | None ->
        Refutation_unsupported
          "open constructor head has no source TypD family identity"
      | Some (source_category, static_args_key) ->
        (match
           Constructor_registry.family_coverage
             (Context.constructors ctx)
             ~source_category
             ~static_args_key
         with
        | Constructor_registry.Open blockers ->
          Refutation_unsupported
            ("constructor family `" ^ source_category
             ^ "` is open: " ^ String.concat "; " blockers)
        | Constructor_registry.Closed entries ->
          let target =
            entries
            |> List.filter (fun entry ->
              entry.Constructor_registry.constructor_op = constructor_op
              && entry.arity = List.length args)
          in
          (match target with
          | [ _ ] ->
            let alternatives =
              entries
              |> List.filter (fun entry ->
                entry.Constructor_registry.constructor_op <> constructor_op)
              |> List.sort_uniq (fun (left : Constructor_registry.entry) right ->
                String.compare left.constructor_op right.constructor_op)
            in
            let built =
              alternatives
              |> List.mapi (fun alt_index entry ->
                Runtime_truth_constructor_pattern.build
                  ~helper_name
                  ~origin
                  ~var_name:(fun field_index _sort ->
                    "RTOPEN" ^ helper_name ^ string_of_int refuter.index
                    ^ "x" ^ string_of_int index
                    ^ "x" ^ string_of_int alt_index
                    ^ "x" ^ string_of_int field_index)
                  entry)
            in
            if List.exists Option.is_none built then
              Refutation_unsupported
                "an alternative constructor lacks complete payload carrier sorts"
            else
              let branches = List.filter_map Fun.id built in
              let new_statements =
                branches
                |> List.concat_map (fun branch ->
                  branch.Runtime_truth_constructor_pattern.declarations
                  @ [ generated
                        helper_name
                        origin
                        (rl
                           ~label:
                             (helper_name ^ "-rule-refuted-"
                              ^ string_of_int refuter.index
                              ^ "-open-head-" ^ string_of_int index)
                           (rule_refuter_call
                              refuter
                              (replace_nth index branch.term input_terms))
                           (rule_refuter_ok refuter))
                    ])
              in
              loop
                (index + 1)
                (List.rev_append new_statements statements)
                (components, patterns)
          | [] ->
            Refutation_unsupported
              ("open constructor `" ^ constructor_op
               ^ "` is absent from its closed registry family")
          | _ :: _ :: _ ->
            Refutation_unsupported
              ("open constructor `" ^ constructor_op
               ^ "` has ambiguous registry identities")))
      )
    | _ :: components, _ :: patterns ->
      loop (index + 1) statements (components, patterns)
    | _, _ -> Refutation_unsupported "relation head/component arity mismatch"
  in
  loop 0 [] (components, pattern_terms)

let head_mismatch_conditions input_terms pattern_terms =
  let rec loop seen acc = function
    | [], [] -> List.rev acc
    | subject :: subjects, Var name :: patterns ->
      (match List.assoc_opt name seen with
      | Some previous ->
        loop
          seen
          (BoolCond (App ("_=/=_", [ subject; previous ])) :: acc)
          (subjects, patterns)
      | None -> loop ((name, subject) :: seen) acc (subjects, patterns))
    | subject :: subjects, pattern :: patterns ->
      (match expected_from_pattern pattern with
      | Pattern_refutable expected ->
        loop
          seen
          (BoolCond (App ("_=/=_", [ subject; expected ])) :: acc)
          (subjects, patterns)
      | Pattern_irrefutable | Pattern_refutation_unsupported _ ->
        loop seen acc (subjects, patterns))
    | _ -> List.rev acc
  in
  loop [] [] (input_terms, pattern_terms)

let rule_refuter_statement ?label helper_name origin refuter lhs conditions =
  match conditions with
  | [] -> None
  | _ ->
    Some
      (generated
         helper_name
         origin
         (crl
            ~label:
              (Option.value label
                 ~default:
                   (helper_name ^ "-rule-refuted-" ^ string_of_int refuter.index))
            lhs
            (rule_refuter_ok refuter)
            (List.map (fun condition -> EqCondition condition) conditions)))

let append_prefix_conditions prefix conditions =
  prefix @ conditions

let head_mismatch_rules helper_name origin refuter input_terms pattern_terms =
  head_mismatch_conditions input_terms pattern_terms
  |> List.filter_map (fun condition ->
    rule_refuter_statement
      helper_name
      origin
      refuter
      (rule_refuter_call refuter input_terms)
      [ condition ])

let head_guard_refuter_rules
    pattern_certificate helper_name origin request rule refuter lhs pattern_terms guards =
  match Runtime_truth_head_guard_refutation.complement
          ~pattern_certificate ~bound_terms:pattern_terms guards with
  | Runtime_truth_head_guard_refutation.Complete alternatives ->
    complete
      (alternatives
       |> List.mapi (fun index conditions ->
         rule_refuter_statement
           ~label:
             (helper_name ^ "-rule-refuted-"
              ^ string_of_int refuter.index ^ "-head-guard-"
              ^ string_of_int (index + 1))
           helper_name origin refuter lhs conditions)
       |> List.filter_map Fun.id)
      []
  | Runtime_truth_head_guard_refutation.Blocked reason ->
    incomplete
      (no_hit_blocker
         ~rule
         request
         origin
         "RuntimeTruthNoHit/RuleD/head-guard"
         (exp_constructor rule.Analysis.Function_graph.head)
         ("matched RuleD head guard is not totally refutable: " ^ reason))

let same_relation_no_hit_condition helper_name request terms =
  let call = no_hit_call ~helper_name request in
  RewriteCond (App (call.op, terms), call.rhs)

let rulepr_components ctx rel_id exp =
  match Analysis.Function_graph.find_relation (Context.function_graph ctx) rel_id with
  | None -> Rule_components.exp_components exp
  | Some relation ->
    let relation_shape = Relation_shape.of_relation relation in
    let expected_count = List.length relation_shape.Relation_shape.components in
    (match Analysis.Relation_graph.exp_components_for_count expected_count exp with
    | Some components -> components
    | None -> Rule_components.exp_components exp)

let typecheck_for_indexed_element_typ ctx env origin typ target target_sort =
  let witness =
    Expr_translate.lower_type_witness
      ctx
      env
      origin
      ~constructor:"RuntimeTruthNoHit/indexed-dependent-element"
      typ
  in
  match witness.term with
  | None -> [], witness.diagnostics
  | Some witness_term ->
    ( witness.guards
      @ Expr_translate.typecheck_conditions_for_typ
          typ
          target_sort
          target
          witness_term
    , witness.diagnostics )

let indexed_dependent_false
    ctx
    helper_name
    origin
    _request
    refuter
    env
    prefix_conditions
    lhs
    rhs
    prem_index
    (rel_id : Il.Ast.id)
    (components : Il.Ast.exp list)
  =
  match Indexed.single_source components with
  | Some
      { component_index = indexed_index
      ; source_exp
      ; element_typ = source_element_typ
      } ->
    (match source_element_typ with
    | None -> None
    | Some source_element_typ ->
      (match Expr_translate.carrier_sort_of_typ source_element_typ with
      | None -> None
      | Some source_element_sort ->
        let source_result =
          Expr_translate.lower_sequence ctx env origin source_exp
        in
        (match source_result.term with
        | None -> None
        | Some source_term ->
          let capture_results =
            components
            |> List.mapi (fun index (component : Il.Ast.exp) ->
              if index = indexed_index then Some None
              else
                let lowered = Expr_translate.lower_value ctx env origin component in
                match lowered.term, Expr_translate.carrier_sort_of_typ component.note with
                | Some term, Some sort ->
                  let source_id =
                    match component.it with
                    | Il.Ast.VarE id -> Some id.it
                    | _ -> None
                  in
                  Some
                    (Some
                       ( index, source_id, term, sort
                       , lowered.guards, lowered.diagnostics ))
                | _ -> None)
          in
          if List.exists Option.is_none capture_results then
            None
          else
            let captures =
              capture_results
              |> List.filter_map (function
                | Some (Some capture) -> Some capture
                | Some None | None -> None)
            in
            let capture_terms =
              captures
              |> List.map (fun (_index, _source_id, term, _sort, _guards, _diags) -> term)
            in
            let capture_sorts =
              captures
              |> List.map (fun (_index, _source_id, _term, sort, _guards, _diags) -> sort)
            in
            let capture_guards =
              captures
              |> List.concat_map
                   (fun (_index, _source_id, _term, _sort, guards, _diags) -> guards)
            in
            let capture_diags =
              captures
              |> List.concat_map
                   (fun (_index, _source_id, _term, _sort, _guards, diags) -> diags)
            in
            let source_ids =
              captures
              |> List.filter_map
                   (fun (_index, source_id, _term, _sort, _guards, _diags) ->
                     source_id)
            in
            let names =
              Local_name.reserve_sources Local_name.empty source_ids
              |> fun names ->
              Local_name.reserve_existing_many names
                (Expr_env.bound_vars env
                 @ List.concat_map Condition_closure.term_vars
                     (lhs :: rhs :: source_term :: capture_terms))
            in
            let formal_captures, names =
              captures
              |> List.fold_left
                   (fun (formals, names)
                        (_index, source_id, _term, sort, _guards, _diags) ->
                     match source_id with
                     | Some source_id ->
                       ( Local_name.source_qualified
                           names source_id (sort_ref sort)
                         :: formals
                       , names )
                     | None ->
                       let formal, names =
                         Local_name.fresh_qualified
                           names Local_name.Capture (sort_ref sort)
                       in
                       formal :: formals, names)
                   ([], names)
              |> fun (formals, names) -> List.rev formals, names
            in
            let head, names =
              Local_name.fresh_qualified
                names Local_name.Head (sort_ref source_element_sort)
            in
            let tail, _names =
              Local_name.fresh_qualified
                names Local_name.Tail (sort_ref spectec_terminals)
            in
            let helper_captures =
              List.map2
                (fun actual formal ->
                  if Condition_closure.term_vars actual = [] then actual else formal)
                capture_terms
                formal_captures
            in
            let input_terms =
              components
              |> List.mapi (fun index _component ->
                if index = indexed_index then
                  Some head
                else
                  let formal_index =
                    List.length
                      (components
                       |> List.filteri (fun earlier _ ->
                         earlier < index && earlier <> indexed_index))
                  in
                  nth_opt helper_captures formal_index)
            in
            let input_sorts =
              components
              |> List.mapi (fun index _component ->
                if index = indexed_index then
                  Some source_element_sort
                else
                  let formal_index =
                    List.length
                      (components
                       |> List.filteri (fun earlier _ ->
                         earlier < index && earlier <> indexed_index))
                  in
                  nth_opt capture_sorts formal_index)
            in
            (match option_all input_terms, option_all input_sorts with
            | Some input_terms, Some input_sorts ->
              let truth_plan =
                Runtime_predicate_search.truth_plan ctx rel_id.it
              in
              (match
                 Runtime_predicate_search.truth_helper_request
                   ~input_terms
                   ~input_sorts
                   truth_plan
               with
            | None -> None
            | Some truth_request ->
                let truth_name =
                  Helper.request
                    (Context.helpers ctx)
                    { Request.kind =
                        Request.Runtime_predicate_truth_search truth_request
                    ; reason = Runtime_truth_search_helper.reason truth_request
                    ; origin
                    }
                in
                let decision_request =
                  { Runtime_truth_decision_helper.truth_helper_name = truth_name
                  ; truth_request
                  }
                in
                let decision_name =
                  Helper.request
                    (Context.helpers ctx)
                    { Request.kind =
                        Request.Runtime_predicate_truth_decision decision_request
                    ; reason =
                        Runtime_truth_decision_helper.reason decision_request
                    ; origin
                    }
                in
                let op_name =
                  indexed_false_op helper_name refuter.index prem_index
                in
                let ok_name =
                  indexed_false_ok_op helper_name refuter.index prem_index
                in
                let result_sort =
                  indexed_false_sort helper_name refuter.index prem_index
                in
                let call source captures =
                  indexed_false_call op_name source captures
                in
                let empty_lhs = call (Const "eps") helper_captures in
                let cons_lhs =
                  call (App ("_ _", [ head; tail ])) helper_captures
                in
                let recursive_lhs = call tail helper_captures in
                let indexed_guards, indexed_diags =
                  typecheck_for_indexed_element_typ
                    ctx
                    env
                    origin
                    source_element_typ
                    head
                    source_element_sort
                in
                let false_condition =
                  Runtime_truth_decision_helper.false_rewrite_condition
                    ~helper_name:decision_name
                    decision_request
                in
                let body_conditions =
                  List.map
                    (fun condition -> EqCondition condition)
                    indexed_guards
                  @ [ false_condition
                    ; RewriteCond (recursive_lhs, Const ok_name)
                    ]
                in
                let statements =
                  [ generated helper_name origin (sort_decl result_sort)
                  ; generated
                      helper_name
                      origin
                      (op
                         op_name
                         (sort_ref spectec_terminals
                          :: List.map sort_ref capture_sorts)
                         result_sort
                         ~attrs:
                           (frozen_all (spectec_terminals :: capture_sorts)))
                  ; generated helper_name origin (op ok_name [] result_sort ~attrs:[ Ctor ])
                  ]
                  @ [ generated
                        helper_name
                        origin
                        (rl
                           ~label:(op_name ^ "-empty")
                           empty_lhs
                           (Const ok_name))
                    ; generated
                        helper_name
                        origin
                        (crl
                           ~label:(op_name ^ "-cons")
                           cons_lhs
                           (Const ok_name)
                           body_conditions)
                    ; generated
                        helper_name
                        origin
                        (crl
                           ~label:
                             (helper_name
                              ^ "-rule-refuted-"
                              ^ string_of_int refuter.index
                              ^ "-indexed-dependent-"
                              ^ string_of_int prem_index)
                           lhs
                           rhs
                           (append_prefix_conditions
                              prefix_conditions
                              (List.map
                                 (fun condition -> EqCondition condition)
                                 (source_result.guards @ capture_guards)
                               @ [ RewriteCond
                                     ( call source_term capture_terms
                                     , Const ok_name )
                                 ])))
                    ]
                in
                Some
                  (complete
                     statements
                     (source_result.diagnostics
                      @ capture_diags
                      @ indexed_diags)))
            | None, _ | _, None -> None))))
  | None -> None

let premise_refuter_rules
    ctx
    helper_name
    origin
    request
    rule
    refuter
    env
    prefix_conditions
    lhs
    prem_index
    (prem : Il.Ast.prem)
  =
  let prem_origin =
    Rule_components.child_origin
      origin
      (Printf.sprintf "premise[%d]" prem_index)
      "Premise"
      prem.at
      (Some (Il.Print.string_of_prem prem))
  in
  let blocked ?diagnostics constructor reason =
    incomplete
      ?diagnostics
      (no_hit_blocker
         ~rule
         ~premise_index:prem_index
         ~premise:prem
         request
         prem_origin
         constructor
         (premise_constructor prem)
         reason)
  in
  match prem.it with
  | Il.Ast.IfPr exp ->
    let source_boolean_refuter () =
      match
        Runtime_truth_total_equality.source_boolean_alternatives
          ctx env prem_origin exp
      with
      | Error blockers ->
        blocked
          ~diagnostics:
            (List.map (Runtime_truth_total_equality.diagnostic ctx) blockers)
          "RuntimeTruthNoHit/IfPr/total-complement"
          ("IfPr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` has no structurally total source Boolean complement: "
           ^ String.concat "; "
               (List.map
                  (fun blocker ->
                    blocker.Runtime_truth_total_equality.reason)
                  blockers))
      | Ok (_, [], diagnostics) ->
        blocked
          ~diagnostics
          "RuntimeTruthNoHit/IfPr/no-false-alternative"
          ("IfPr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` has no AST-derived false alternative")
      | Ok (_, _ :: _, diagnostics)
        when List.exists Diagnostics.is_fatal diagnostics ->
        blocked
          ~diagnostics
          "RuntimeTruthNoHit/IfPr/fatal-complement"
          ("IfPr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` retained a fatal totality/lowering diagnostic")
      | Ok (_, alternatives, diagnostics) ->
        let statements =
          alternatives
          |> List.mapi (fun alternative conditions ->
            generated
              helper_name
              prem_origin
              (crl
                 ~label:
                   (helper_name
                    ^ "-rule-refuted-"
                    ^ string_of_int refuter.index
                    ^ "-if-"
                    ^ string_of_int prem_index
                    ^ "-alternative-"
                    ^ string_of_int (alternative + 1))
                 lhs
                 (rule_refuter_ok refuter)
                 (append_prefix_conditions
                    prefix_conditions
                    (List.map
                       (fun condition -> EqCondition condition)
                       conditions))))
        in
        complete statements diagnostics
    in
    (match exp.it with
    | Il.Ast.CmpE (`EqOp, _, left, right) ->
      (match
         Runtime_truth_equality_pattern_refuter.refute
           ctx
           ~helper_name
           ~origin:prem_origin
           ~env
           ~refuter_index:refuter.index
           ~prem_index
           ~prefix_conditions
           ~lhs
           ~rhs:(rule_refuter_ok refuter)
           ~left
           ~right
       with
      | Some result -> complete result.statements result.diagnostics
      | None -> source_boolean_refuter ())
    | _ -> source_boolean_refuter ())
  | Il.Ast.RulePr (rel_id, [], _mixop, exp) ->
    let components = rulepr_components ctx rel_id.it exp in
    if
      String.equal
        rel_id.it
        request.Runtime_truth_decision_helper.truth_request.rel_id
    then
      let lowered =
        Rule_components.lower_value_components ctx env prem_origin components
      in
      if List.exists Diagnostics.is_fatal lowered.diagnostics then
        blocked
          ~diagnostics:lowered.diagnostics
          "RuntimeTruthNoHit/RulePr/component-lowering"
          ("RulePr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` did not lower to bound Maude values")
      else
        match lowered.values with
        | Some (terms, _sorts) ->
        complete
          [ generated
              helper_name
              prem_origin
              (crl
                 ~label:
                   (helper_name
                    ^ "-rule-refuted-"
                    ^ string_of_int refuter.index
                    ^ "-recursive-"
                    ^ string_of_int prem_index)
                 lhs
                 (rule_refuter_ok refuter)
                 (append_prefix_conditions
                    prefix_conditions
                    (List.map
                       (fun condition -> EqCondition condition)
                       lowered.guards
                     @ [ same_relation_no_hit_condition helper_name request terms ])))
          ]
          lowered.diagnostics
        | None ->
          blocked
            ~diagnostics:lowered.diagnostics
            "RuntimeTruthNoHit/RulePr/unbound-components"
            ("RulePr premise `"
             ^ Il.Print.string_of_prem prem
             ^ "` did not lower to already-bound Maude values")
    else
      (match
        Runtime_truth_deterministic_false.materialize
          ctx
          ~helper_name
          ~origin:prem_origin
          ~env
          ~label:
            (helper_name
             ^ "-rule-refuted-"
             ^ string_of_int refuter.index
             ^ "-deterministic-"
             ^ string_of_int prem_index)
          ~lhs
          ~rhs:(rule_refuter_ok refuter)
          ~rel_id
          ~exp
      with
      | Runtime_truth_deterministic_false.Materialized
          { statements; diagnostics } ->
        complete statements diagnostics
      | Runtime_truth_deterministic_false.Materialization_blocked
          { diagnostics; blockers } ->
        blocked
          ~diagnostics
          "RuntimeTruthNoHit/RulePr/deterministic-false"
          ("deterministic RulePr premise `"
           ^ Il.Print.string_of_prem prem
           ^ "` has no source-complete false decision: "
           ^ String.concat "; " blockers)
      | Runtime_truth_deterministic_false.Not_deterministic_materialization ->
        (match
           indexed_dependent_false
             ctx
             helper_name
             prem_origin
             request
             refuter
             env
             prefix_conditions
             lhs
             (rule_refuter_ok refuter)
             prem_index
             rel_id
             components
         with
        | Some result -> result
        | None ->
        (match
          Runtime_truth_dependent_false.lower
            ctx
            prem_origin
            env
            ~rel_id:rel_id.it
            ~components
         with
        | Runtime_truth_dependent_false.Complete conditions ->
          complete
            [ generated
                helper_name
                prem_origin
                (crl
                   ~label:
                     (helper_name
                      ^ "-rule-refuted-"
                      ^ string_of_int refuter.index
                      ^ "-dependent-"
                      ^ string_of_int prem_index)
                   lhs
                   (rule_refuter_ok refuter)
                   (append_prefix_conditions prefix_conditions conditions))
            ]
            []
        | Runtime_truth_dependent_false.Blocked { diagnostics; blockers } ->
          let reasons =
            blockers
            |> List.map Runtime_truth_dependent_false.blocker_reason
            |> String.concat "; "
          in
          blocked
            ~diagnostics:
              (diagnostics
               @ List.map
                   (Runtime_truth_dependent_false.blocker_diagnostic ctx)
                   blockers)
            "RuntimeTruthNoHit/RulePr/dependent-false"
            ("dependent RulePr premise `"
             ^ Il.Print.string_of_prem prem
             ^ "` has no source-complete false decision: "
             ^ reasons))))
  | Il.Ast.RulePr (_, _ :: _, _, _)
  | Il.Ast.LetPr _ | Il.Ast.ElsePr | Il.Ast.IterPr _ | Il.Ast.NegPr _ ->
    blocked
      "RuntimeTruthNoHit/Premise/unsupported-constructor"
      ("premise constructor in `"
       ^ Il.Print.string_of_prem prem
       ^ "` is not supported by finite no-hit refutation")

let indexed_head_refuter_rules
    ctx helper_name origin request refuter input_terms components rule
  =
  let blocked ?diagnostics ?exp constructor reason =
    let ast_constructor =
      match exp with
      | Some exp -> exp_constructor exp
      | None -> exp_constructor rule.Analysis.Function_graph.head
    in
    incomplete
      ?diagnostics
      (no_hit_blocker
         ~rule request origin constructor ast_constructor reason)
  in
  match Indexed.single_source components with
  | Some
      { component_index = indexed_index
      ; source_exp
      ; element_typ = source_element_typ
      } ->
    (match source_element_typ with
    | None ->
      blocked
        ~exp:source_exp
        "RuntimeTruthNoHit/RuleD/indexed-head-element-type"
        ("indexed head source `"
         ^ Il.Print.string_of_exp source_exp
         ^ "` has no list element type")
    | Some source_element_typ ->
      (match Expr_translate.carrier_sort_of_typ source_element_typ with
      | None ->
        blocked
          ~exp:source_exp
          "RuntimeTruthNoHit/RuleD/indexed-head-carrier"
          ("indexed head source element type `"
           ^ Il.Print.string_of_typ source_element_typ
           ^ "` has no Maude carrier")
      | Some source_element_sort ->
        let source_names =
          components
          |> List.concat_map (fun exp ->
            Il.Free.(free_exp exp).varid |> Il.Free.Set.elements)
          |> List.sort_uniq String.compare
        in
        let names = Local_name.reserve_sources Local_name.empty source_names in
        let rec lower_head names env terms guards diagnostics index = function
          | [] ->
            Some
              ( env
              , List.rev terms
              , List.rev guards
              , List.rev diagnostics
              , names )
          | component :: rest ->
            if index = indexed_index then
              match nth_opt input_terms indexed_index with
              | None -> None
              | Some indexed_term ->
                lower_head names
                  env
                  (indexed_term :: terms)
                  guards
                  diagnostics
                  (index + 1)
                  rest
            else
              let result, names =
                Expr_translate.lower_pattern_with_bindings_named
                  names ctx
                  env
                  origin
                  component
              in
              (match result.pattern_term with
              | None -> None
              | Some term ->
                let env =
                  List.fold_left
                    (fun env (id, binding) ->
                      Expr_env.add env id binding)
                    env
                    result.introduced_bindings
                in
                lower_head names
                  env
                  (term :: terms)
                  (List.rev_append result.pattern_guards guards)
                  (List.rev_append result.pattern_diagnostics diagnostics)
                  (index + 1)
                  rest)
        in
        let initial_env = specialized_head_env request components in
        (match lower_head names initial_env [] [] [] 0 components with
        | None ->
          blocked
            "RuntimeTruthNoHit/RuleD/indexed-head-pattern"
            "indexed head rule has non-indexed components that do not lower to source patterns"
        | Some (env, pattern_terms, head_guards, head_diagnostics, names) ->
          let prefix_result, names =
            Premise_translate.translate_premises_named
              names
              ~allow_runtime_search:true
              ~discharge_static_validation:false
              ctx
              env
              ~bound_conditions:head_guards
              ~escape_source_ids:[]
              ~bound_terms:pattern_terms
              origin
              rule.Analysis.Function_graph.prems
          in
          (match prefix_result with
          | Premise_result.Blocked diagnostics
          | Deferred (_, diagnostics) ->
            blocked
              ~diagnostics:(head_diagnostics @ diagnostics)
              "RuntimeTruthNoHit/RuleD/indexed-head-prefix"
              "indexed head rule premises did not lower source-completely"
          | Complete prefix_result ->
            let source_result =
              Expr_translate.lower_sequence
                ctx
                (Premise_result.env_after prefix_result)
                origin
                source_exp
            in
            (match source_result.term with
            | None ->
              blocked
                ~diagnostics:
                  (head_diagnostics
                   @ Premise_result.diagnostics prefix_result
                   @ source_result.diagnostics)
                ~exp:source_exp
                "RuntimeTruthNoHit/RuleD/indexed-head-source"
                ("indexed head source `"
                 ^ Il.Print.string_of_exp source_exp
                 ^ "` did not lower after source premises")
            | Some source_term ->
              let op_name =
                indexed_head_no_match_op helper_name refuter.index
              in
              let ok_name =
                indexed_head_no_match_ok_op helper_name refuter.index
              in
              let result_sort =
                indexed_head_no_match_sort helper_name refuter.index
              in
              let names =
                Local_name.reserve_existing_many names
                  (Expr_env.bound_vars
                     (Premise_result.env_after prefix_result)
                   @ List.concat_map Condition_closure.term_vars
                       (source_term :: input_terms @ pattern_terms))
              in
              let target, names =
                Local_name.fresh_qualified
                  names Local_name.Value (sort_ref source_element_sort)
              in
              let head, names =
                Local_name.fresh_qualified
                  names Local_name.Head (sort_ref source_element_sort)
              in
              let tail, _names =
                Local_name.fresh_qualified
                  names Local_name.Tail (sort_ref spectec_terminals)
              in
              let call target source =
                indexed_head_no_match_call op_name target source
              in
              (match nth_opt input_terms indexed_index with
              | None ->
                blocked
                  "RuntimeTruthNoHit/RuleD/indexed-head-target"
                  "indexed head target component is not available"
              | Some target_term ->
                let lhs = rule_refuter_call refuter pattern_terms in
                let statements =
                  [ generated helper_name origin (sort_decl result_sort)
                  ; generated
                      helper_name
                      origin
                      (op
                         op_name
                         [ sort_ref source_element_sort
                         ; sort_ref spectec_terminals
                         ]
                         result_sort
                         ~attrs:
                           (frozen_all [ source_element_sort; spectec_terminals ]))
                  ; generated helper_name origin (op ok_name [] result_sort ~attrs:[ Ctor ])
                  ; generated
                      helper_name
                      origin
                      (rl
                         ~label:(op_name ^ "-empty")
                         (call target (Const "eps"))
                         (Const ok_name))
                  ; generated
                      helper_name
                      origin
                      (crl
                         ~label:(op_name ^ "-cons")
                         (call target (App ("_ _", [ head; tail ])))
                         (Const ok_name)
                         [ EqCondition (BoolCond (App ("_=/=_", [ target; head ])))
                         ; RewriteCond (call target tail, Const ok_name)
                         ])
                  ; generated
                      helper_name
                      origin
                      (crl
                         ~label:
                           (helper_name
                            ^ "-rule-refuted-"
                            ^ string_of_int refuter.index
                            ^ "-indexed-head")
                         lhs
                         (rule_refuter_ok refuter)
                         (List.map
                            (fun condition -> EqCondition condition)
                            (head_guards
                             @ Premise_result.eq_conditions prefix_result
                             @ source_result.guards)
                          @ Premise_result.rule_conditions prefix_result
                          @ [ RewriteCond
                                ( call target_term source_term
                                , Const ok_name )
                            ]))
                  ]
                in
                complete
                  statements
                  (head_diagnostics
                   @ Premise_result.diagnostics prefix_result
                   @ source_result.diagnostics)))))))
  | None ->
    blocked
      "RuntimeTruthNoHit/RuleD/head-pattern"
      "source RuleD head pattern did not lower to Maude patterns"

let rule_refuter_rules ctx helper_name origin request input_terms rules =
  let truth_request = request.Runtime_truth_decision_helper.truth_request in
  let input_count = List.length truth_request.input_terms in
  let lower_rule index rule =
    let refuter = rule_refuter helper_name index in
    let origin =
      Rule_components.child_origin
        origin
        (Printf.sprintf "RuleD[%d]" index)
        "RuleD"
        rule.Analysis.Function_graph.origin.region
        rule.Analysis.Function_graph.source_echo
    in
    let blocked ?diagnostics constructor reason =
      incomplete
        ?diagnostics
        (no_hit_blocker
           ~rule
           request
           origin
           constructor
           (exp_constructor rule.Analysis.Function_graph.head)
           reason)
    in
    match
      Analysis.Relation_graph.exp_components_for_count input_count rule.head
    with
    | None ->
      blocked
        "RuntimeTruthNoHit/RuleD/head-arity"
        ("source RuleD `"
         ^ Option.value
             ~default:("RuleD[" ^ string_of_int index ^ "]")
             rule.Analysis.Function_graph.rule_id
         ^ "` head does not match the runtime truth arity")
    | Some components ->
      let lowered_head =
        Rule_components.lower_complete_head_patterns
          Local_name.empty ~env:(specialized_head_env request components)
          ctx origin components
      in
      (match lowered_head.terms with
      | None ->
        let indexed_head =
          indexed_head_refuter_rules
            ctx
            helper_name
            origin
            request
            refuter
            input_terms
            components
            rule
        in
        { indexed_head with
          diagnostics =
            if indexed_head.complete then
              indexed_head.diagnostics
            else
              lowered_head.diagnostics @ indexed_head.diagnostics
        ; blockers =
            if indexed_head.complete then
              indexed_head.blockers
            else
              no_hit_blocker
                ~rule
                request
                origin
                "RuntimeTruthNoHit/RuleD/head-pattern"
                (exp_constructor rule.Analysis.Function_graph.head)
                ("source RuleD `"
                 ^ Option.value
                     ~default:("RuleD[" ^ string_of_int index ^ "]")
                     rule.Analysis.Function_graph.rule_id
                 ^ "` head pattern did not lower to Maude patterns")
              :: indexed_head.blockers
        }
      | Some pattern_terms ->
        let lhs = rule_refuter_call refuter pattern_terms in
        let open_head =
          open_head_refutation
            ctx helper_name origin refuter input_terms components pattern_terms
        in
        (match open_head with
        | Refutation_unsupported reason ->
          blocked
            "RuntimeTruthNoHit/RuleD/open-constructor-head"
            ("source RuleD open-constructor head is not exhaustively refutable: "
             ^ reason)
        | Irrefutable | Refutable _ ->
        let open_head_rules =
          match open_head with
          | Refutable statements -> statements
          | Irrefutable | Refutation_unsupported _ -> []
        in
        let guard_refuters =
          head_guard_refuter_rules
            (Condition_closure.source_constructor_certificate ctx)
            helper_name origin request rule refuter lhs pattern_terms lowered_head.guards
        in
        let head_rules =
          open_head_rules
          @ head_mismatch_rules helper_name origin refuter input_terms pattern_terms
          @ guard_refuters.statements
        in
        (* For a source rule with premises P1 ... Pn, refuting the whole
           conjunction is the finite disjunction

             not P1
             or P1 /\ not P2
             or ...
             or P1 /\ ... /\ P(n-1) /\ not Pn.

           We materialize one CRL per branch.  This is the point where
           source-bound variables introduced by earlier premises (for example
           an equality that binds a list used by a later indexed RulePr) become
           visible to the later false premise. *)
        let rec premise_refuters prefix index acc = function
          | [] -> acc
          | prem :: rest ->
            let prefix_result =
              Premise_translate.translate_premises
                ~allow_runtime_search:true
                ~discharge_static_validation:false
                ctx
                lowered_head.env
                ~bound_conditions:lowered_head.guards
                ~escape_source_ids:[]
                ~bound_terms:pattern_terms
                origin
                (List.rev prefix)
            in
            (match prefix_result with
            | Premise_result.Blocked diagnostics
            | Deferred (_, diagnostics) ->
              let current =
                incomplete
                  ~diagnostics
                  (no_hit_blocker
                     ~rule
                     ~premise_index:index
                     ~premise:prem
                     request
                     origin
                     "RuntimeTruthNoHit/RuleD/premise-prefix"
                     (premise_constructor prem)
                     ("source RuleD `"
                      ^ Option.value
                          ~default:("RuleD[" ^ string_of_int index ^ "]")
                          rule.Analysis.Function_graph.rule_id
                      ^ "` prefix premises before premise["
                      ^ string_of_int index
                      ^ "] did not lower source-completely"))
              in
              append_refuters acc current
            | Complete prefix_result ->
              let prefix_conditions =
                List.map
                  (fun condition -> EqCondition condition)
                  (lowered_head.guards
                   @ Premise_result.eq_conditions prefix_result)
                @ Premise_result.rule_conditions prefix_result
              in
              let current =
                premise_refuter_rules
                  ctx
                  helper_name
                  origin
                  request
                  rule
                  refuter
                  (Premise_result.env_after prefix_result)
                  prefix_conditions
                  lhs
                  index
                  prem
              in
              premise_refuters
                (prem :: prefix)
                (index + 1)
                (append_refuters acc current)
                rest)
        in
        let premise_refuters =
          premise_refuters [] 1 (complete [] []) rule.prems
        in
        let statements = head_rules @ premise_refuters.statements in
        let has_refuter =
          match statements with
          | [] -> false
          | _ :: _ -> true
        in
        { statements
        ; diagnostics =
            lowered_head.diagnostics @ guard_refuters.diagnostics
            @ premise_refuters.diagnostics
        ; complete = has_refuter && guard_refuters.complete && premise_refuters.complete
        ; blockers =
            guard_refuters.blockers @ premise_refuters.blockers
            @
            if has_refuter then []
            else
              [ no_hit_blocker
                  ~rule
                  request
                  origin
                  "RuntimeTruthNoHit/RuleD/no-refuter"
                  (exp_constructor rule.Analysis.Function_graph.head)
                  ("source RuleD `"
                   ^ Option.value
                       ~default:("RuleD[" ^ string_of_int index ^ "]")
                       rule.Analysis.Function_graph.rule_id
                   ^ "` has no generated head or premise refuter")
              ]
        })
        )
  in
  rules
  |> List.mapi (fun index rule -> lower_rule (index + 1) rule)
  |> List.fold_left append_refuters (complete [] [])

let all_rules_rule helper_name origin input_terms rules =
  let conditions =
    rules
    |> List.mapi (fun index _rule ->
      let refuter = rule_refuter helper_name (index + 1) in
      RewriteCond (rule_refuter_call refuter input_terms, rule_refuter_ok refuter))
  in
  match conditions with
  | [] -> []
  | _ ->
    [ generated
        helper_name
        origin
        (crl
           ~label:(helper_name ^ "-all-rules-refuted")
           (all_rules_call ~helper_name input_terms)
           (all_rules_ok helper_name)
           conditions)
    ]

let blocker_diagnostic ctx blocker =
  let rule = Option.value ~default:"<anonymous>" blocker.rule_id in
  let enclosing =
    Diagnostic_provenance.enclosing
      ~context:(Context.enclosing_path ctx) blocker.origin
    @ [ "relation " ^ blocker.relation_id; "rule " ^ rule ]
    @ (match blocker.premise_index with
       | None -> []
       | Some index -> [ "source premise " ^ string_of_int index ])
    @ (match blocker.premise_context with
       | None -> []
       | Some premise -> [ "premise " ^ premise ])
  in
  Diagnostics.make
    ~category:Diagnostics.Unsupported
    ~origin:blocker.origin
    ~constructor:(blocker.constructor ^ "/" ^ blocker.ast_constructor)
    ~enclosing
    ~profile:(Context.profile_name ctx)
    ~reason:blocker.reason
    ~suggestion:blocker.suggestion
    ?source_echo:blocker.source_echo
    ()

let finite_transitive ctx ~helper_name:_ ~origin request _domain =
  Blocked
    [ Diagnostics.make
        ~category:Diagnostics.Unsupported
        ~origin
        ~constructor:"RuntimeTruthNoHit/ownership/finite-transitive"
        ~enclosing:
          (Diagnostic_provenance.enclosing
             ~context:(Context.enclosing_path ctx) origin)
        ~profile:(Context.profile_name ctx)
        ~reason:
          "finite-transitive no-hit/refutation is exclusively owned by the SCC worklist engine; the legacy no-hit engine cannot materialize this request"
        ~suggestion:
          "Route recursive/transitive truth through Runtime_truth_scc with explicit exhaustive domain coverage"
        ~source_echo:(Runtime_truth_decision_helper.reason request)
        ()
    ]

let acyclic_no_hit_entry_rule helper_name origin request input_terms =
  let no_hit = no_hit_call ~helper_name request in
  [ generated
      helper_name
      origin
      (crl
         ~label:(helper_name ^ "-acyclic-no-hit")
         (App (no_hit.op, input_terms))
         no_hit.rhs
         [ RewriteCond
             (all_rules_call ~helper_name input_terms, all_rules_ok helper_name)
         ])
  ]

let acyclic ctx ~helper_name ~origin request =
  let stage = Context.begin_stage ctx in
  let staged_ctx = Context.staged stage in
  let call = no_hit_call ~helper_name request in
  let rules = local_rules request in
  let input_terms, _names = specialized_input_terms request in
  let refuters =
    rule_refuter_rules staged_ctx helper_name origin request input_terms rules
  in
  let diagnostics =
    if refuters.complete then
      refuters.diagnostics
    else
      refuters.diagnostics
      @ List.map (blocker_diagnostic ctx) refuters.blockers
  in
  if List.exists Diagnostics.is_fatal diagnostics then
    Blocked diagnostics
  else (
    Context.commit_stage stage;
    Complete
      { statements =
          no_hit_surface helper_name origin request
          @ all_rules_surface helper_name origin request
          @ rule_refuter_surface helper_name origin request rules
          @ all_rules_rule helper_name origin input_terms rules
          @ refuters.statements
          @ acyclic_no_hit_entry_rule helper_name origin request input_terms
      ; conditions = [ RewriteCond (call.lhs, call.rhs) ]
      ; diagnostics
      })
