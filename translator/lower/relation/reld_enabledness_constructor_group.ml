open Il.Ast
open Maude_ir
open Util.Source

open Reld_result
open Reld_rule_lowering
open Reld_enabledness_direct_complement

let helper_name origin =
  Naming.helper_op
    ~role:"enabledness-group"
    ~owner:(Naming.helper_owner origin)

let helper_sort name =
  sort ("RuntimeEnabledness" ^ Naming.sort_token name ^ "Conf")

let helper_op name = name

let false_op name =
  Naming.helper_companion ~role:"enabledness-group-false" name

let generated_helper name origin node =
  Maude_ir.generated ~provenance:(Maude_ir.Helper name) ~origin node

let helper_surface name origin input_sorts =
  let result_sort = helper_sort name in
  [ generated_helper name origin (sort_decl result_sort)
  ; generated_helper
      name
      origin
      (op
         (helper_op name)
         (List.map sort_ref input_sorts)
         result_sort
         ~attrs:(frozen_all (List.length input_sorts)))
  ; generated_helper
      name
      origin
      (op (false_op name) [] result_sort ~attrs:[ Ctor ])
  ]

type branch =
  | False_branch of Maude_ir.generated list * Diagnostics.t list
  | Covered_branch of Diagnostics.t list
  | Blocked_branch of Diagnostics.t list
  | Not_same_head

type result =
  | Materialized of Reld_result.output * Maude_ir.rule_condition list
  | Blocked of Diagnostics.t list
  | Not_applicable

let false_branch
    ctx
    rel_origin
    relation_id
    relation_kind
    relation_mixop
    (shape : Relation_shape.execution_shape)
    current_lhs_terms
    name
    index
    rule =
  let origin = rule_origin rel_origin index rule in
  match rule.it with
  | RuleD (rule_id, binds, _mixop, exp, prems) ->
    let names = local_names_for_rule rule in
    let ctx = Context.with_rule ctx rule_id.it in
    let hint_diags = rule_hint_diagnostics ctx origin relation_id.it rule_id in
    let marker_diags =
      validate_rule_marker
        ctx
        origin
        ~expected_kind:relation_kind
        ~expected_mixop:relation_mixop
        rule
    in
    if has_fatal hint_diags || has_fatal marker_diags then
      Blocked_branch (hint_diags @ marker_diags)
    else
      let input_typs =
        Relation_shape.component_typs shape.Relation_shape.inputs
      in
      let output_typs =
        Relation_shape.component_typs shape.Relation_shape.outputs
      in
      let expected_typs = input_typs @ output_typs in
      let components_opt, arity_diags =
        exp_components_match
          ctx
          origin
          "RelD/ElsePr/enabledness/group-arity"
          expected_typs
          exp
      in
      (match components_opt with
      | None -> Blocked_branch (hint_diags @ marker_diags @ arity_diags)
      | Some components ->
        let input_count = List.length input_typs in
        let rec split n left right =
          if n = 0 then List.rev left, right
          else
            match right with
            | [] -> List.rev left, []
            | item :: rest -> split (n - 1) (item :: left) rest
        in
        let input_exps, _output_exps = split input_count [] components in
        let env, var_decls, bind_diags, names =
          translate_rule_binds ctx origin names binds
        in
        let (lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags), names =
          lower_pattern_components_named names ctx env origin input_exps
        in
        (match lhs_terms_opt with
        | Some lhs_terms
          when predecessor_matches_current current_lhs_terms lhs_terms
               && predecessor_refines_constructor current_lhs_terms lhs_terms ->
          let env =
            add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings
          in
          let premise_translation, _names =
            let prems =
              prems
              |> List.filter (fun prem ->
                match prem.it with
                | ElsePr -> false
                | _ -> true)
            in
            Premise_translate.translate_premises_named
              names
              ~allow_runtime_search:true
              ctx
              env
              ~bound_conditions:lhs_guards
              ~bound_terms:lhs_terms
              origin
              prems
          in
          (match premise_translation with
          | Premise_result.Blocked diagnostics
          | Deferred (_, diagnostics) ->
            Blocked_branch
              (hint_diags @ marker_diags @ arity_diags @ bind_diags
               @ lhs_diags @ diagnostics)
          | Complete premise_result ->
          let diagnostics =
            hint_diags @ marker_diags @ arity_diags @ bind_diags
            @ lhs_diags @ Premise_result.diagnostics premise_result
          in
          if has_fatal diagnostics then
            Blocked_branch diagnostics
          else if Premise_result.rule_conditions premise_result <> [] then
            Blocked_branch
              (diagnostics
               @ [ unsupported
                     ~ctx
                     ~origin
                     ~constructor:"RelD/ElsePr/enabledness/group-rewrite"
                     ~source_echo:(Il.Print.string_of_rule rule)
                     ~reason:
                       "constructor-group otherwise complement cannot refute predecessor rules with rewrite conditions"
                     ~suggestion:
                       "Keep this predecessor Unsupported until its rewrite-dependent enabledness has a source-complete false helper"
                     ()
                 ])
          else
            (match
               certified_sequential_complement_alternatives
                 ~lhs_conditions:lhs_guards
                 (Context.constructors ctx)
                 ~origin
                 ~helper_name:name
                 ~condition_certificates:
                   (Premise_result.source_condition_certificates premise_result)
                 ~condition_failures:
                   (Premise_result.source_condition_failures premise_result)
                 lhs_terms
                 (Premise_result.eq_conditions premise_result)
             with
            | Complete { alternatives = []; statements = _ } ->
              Covered_branch diagnostics
            | Blocked reasons ->
              Blocked_branch
                (diagnostics
                 @ [ unsupported
                       ~ctx
                       ~origin
                       ~constructor:"RelD/ElsePr/enabledness/group-complement"
                       ~source_echo:(Il.Print.string_of_rule rule)
                       ~reason:
                         ("constructor-group predecessor complement is incomplete: "
                          ^ String.concat "; " reasons)
                       ~suggestion:
                         "Keep this otherwise branch Unsupported until every source-ordered first-failure case has a total Boolean representation"
                       () ])
            | Complete complete ->
              let lhs = App (helper_op name, lhs_terms) in
              let rhs = Const (false_op name) in
              let rules =
                complete.alternatives
                |> List.mapi (fun alternative_index complement ->
                  let conditions =
                    List.map (fun condition -> EqCondition condition) lhs_guards
                    @ complement
                    |> Condition_closure.normalize_rule_conditions
                         ~constructor_op:
                           (Condition_closure.source_constructor_certificate ctx)
                         [ lhs ]
                    |> dedup_rule_conditions
                  in
                  let diagnostics =
                    Condition_admissibility.crl_admissibility_diagnostics
                      ctx origin lhs rhs conditions
                  in
                  let statement =
                    generated_helper name origin
                      (crl
                         ~label:
                           (Maude_ir.sanitize_label
                              (name ^ "-false-" ^ string_of_int index ^ "-"
                               ^ string_of_int (alternative_index + 1)))
                         lhs rhs conditions)
                  in
                  statement, diagnostics)
              in
              let admissibility_diags = List.concat_map snd rules in
              if has_fatal admissibility_diags then
                Blocked_branch (diagnostics @ admissibility_diags)
              else
                let registry_diags =
                  rules
                  |> List.concat_map (fun (statement, _) ->
                    generated_statement_diagnostics ctx statement)
                in
                if has_fatal registry_diags then
                  Blocked_branch (diagnostics @ registry_diags)
                else
                  False_branch
                    ( var_decls @ complete.statements @ List.map fst rules
                    , diagnostics )))
        | Some _ -> Not_same_head
        | None ->
          Blocked_branch
            (hint_diags @ marker_diags @ arity_diags @ bind_diags @ lhs_diags)))

let complement
    ctx
    ~rel_origin
    ~relation_id
    ~relation_kind
    ~relation_mixop
    shape
    ~input_sorts
    ~origin
    ~current_lhs_terms
    ~previous_rules =
  let name = helper_name origin in
  let branches =
    previous_rules
    |> List.mapi (fun index rule ->
      false_branch
        ctx
        rel_origin
        relation_id
        relation_kind
        relation_mixop
        shape
        current_lhs_terms
        name
        (index + 1)
        rule)
  in
  let rec collect false_statements diagnostics = function
    | [] -> Ok (List.rev false_statements, List.rev diagnostics)
    | Not_same_head :: rest -> collect false_statements diagnostics rest
    | Covered_branch diags :: rest ->
      collect false_statements (List.rev_append diags diagnostics) rest
    | False_branch (statements, diags) :: rest ->
      collect
        (List.rev_append statements false_statements)
        (List.rev_append diags diagnostics)
        rest
    | Blocked_branch diags :: _ ->
      if has_fatal diags then Error diags else collect false_statements diagnostics []
  in
  match collect [] [] branches with
  | Error diagnostics -> Blocked diagnostics
  | Ok (false_statements, diagnostics) ->
    (match false_statements with
    | [] -> Not_applicable
    | _ :: _ ->
      let statements = helper_surface name origin input_sorts @ false_statements in
      let condition =
        RewriteCond
          ( App (helper_op name, current_lhs_terms)
          , Const (false_op name) )
      in
      Materialized ({ statements; diagnostics }, [ condition ]))
