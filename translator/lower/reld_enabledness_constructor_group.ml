open Il.Ast
open Maude_ir
open Util.Source

open Reld_common
open Reld_enabledness_direct_complement

let helper_name origin =
  let digest = Digest.to_hex (Digest.string (Origin.summary origin)) in
  "EnablednessGroup" ^ Naming.helper_context_name origin ^ String.sub digest 0 8

let helper_sort name =
  sort ("RuntimeEnabledness" ^ name ^ "Conf")

let helper_op name =
  "runtimeEnabledness" ^ name

let false_op name =
  "runtimeEnablednessFalse" ^ name

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
        let env, var_decls, bind_diags =
          translate_rule_binds
            ctx
            origin
            (name ^ "-rule-" ^ string_of_int index)
            binds
        in
        let lhs_terms_opt, lhs_guards, lhs_bindings, lhs_diags =
          lower_pattern_components ctx env origin input_exps
        in
        (match lhs_terms_opt with
        | Some lhs_terms
          when predecessor_matches_current current_lhs_terms lhs_terms
               && predecessor_refines_constructor current_lhs_terms lhs_terms ->
          let env =
            add_safe_introduced_bindings env lhs_terms lhs_guards lhs_bindings
          in
          let premise_result =
            let prems =
              prems
              |> List.filter (fun prem ->
                match prem.it with
                | ElsePr -> false
                | _ -> true)
            in
            Premise_translate.translate_premises
              ~allow_runtime_search:true
              ctx
              env
              ~bound_conditions:lhs_guards
              ~bound_terms:lhs_terms
              origin
              prems
          in
          let diagnostics =
            hint_diags @ marker_diags @ arity_diags @ bind_diags
            @ lhs_diags @ premise_result.diagnostics
          in
          if has_fatal diagnostics then
            Blocked_branch diagnostics
          else if premise_result.rule_conditions <> [] then
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
               sequential_complement_conditions
                 lhs_terms
                 premise_result.eq_conditions
             with
            | None -> Covered_branch diagnostics
            | Some complement ->
              let lhs = App (helper_op name, lhs_terms) in
              let rhs = Const (false_op name) in
              let conditions =
                List.map (fun condition -> EqCondition condition) lhs_guards
                @ complement
                |> Condition_closure.normalize_rule_conditions [ lhs ]
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
              if has_fatal admissibility_diags then
                Blocked_branch (diagnostics @ admissibility_diags)
              else
                let statement =
                  generated_helper
                    name
                    origin
                    (crl
                       ~label:
                         (Maude_ir.sanitize_label
                            (name ^ "-false-" ^ string_of_int index))
                       lhs
                       rhs
                       conditions)
                in
                let registry_diags =
                  generated_statement_diagnostics ctx statement
                in
                if has_fatal registry_diags then
                  Blocked_branch (diagnostics @ registry_diags)
                else
                  False_branch (var_decls @ [ statement ], diagnostics))
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
    | [] -> Some (List.rev false_statements, List.rev diagnostics)
    | Not_same_head :: rest -> collect false_statements diagnostics rest
    | Covered_branch diags :: rest ->
      collect false_statements (List.rev_append diags diagnostics) rest
    | False_branch (statements, diags) :: rest ->
      collect
        (List.rev_append statements false_statements)
        (List.rev_append diags diagnostics)
        rest
    | Blocked_branch diags :: _ ->
      if has_fatal diags then None else collect false_statements diagnostics []
  in
  match collect [] [] branches with
  | None -> None
  | Some (false_statements, diagnostics) ->
    (match false_statements with
    | [] -> None
    | _ :: _ ->
      let statements = helper_surface name origin input_sorts @ false_statements in
      let condition =
        RewriteCond
          ( App (helper_op name, current_lhs_terms)
          , Const (false_op name) )
      in
      Some ({ statements; diagnostics }, [ condition ]))
