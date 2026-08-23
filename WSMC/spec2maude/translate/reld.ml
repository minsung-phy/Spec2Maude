open Util.Source
open Il.Ast
open Maude_il


let frozen_all count =
  match List.init count (( + ) 1) with
  | [] -> []
  | positions -> [Frozen positions]

let component_types typ =
  match typ.it with
  | TupT fields -> List.map snd fields
  | _ -> [typ]

let output_sort index = function
  | [typ] -> Term.translate_sort index typ
  | _ :: _ :: _ -> "SpectecTerminal"
  | [] -> invalid_arg "relation policy has no output component"

let translate_inputs index params inputs =
  let bound = Il.Free.(bound_params params).varid in
  let step (terms, conditions, bound) (position, exp) =
    match Prem.translate_pattern_parts index exp with
    | Some (term, guards) ->
        ( term :: terms
        , conditions @ List.map (fun guard -> EqCondition guard) guards
        , Prem.bind bound exp
        )
    | None ->
        let subject =
          Var
            (generated_variable
               ("REL-INPUT" ^ string_of_int (position + 1))
               (Term.translate_sort index exp.note))
        in
        let binding =
          Prem.bind_pattern index bound exp subject
            "relation input is not a structural pattern"
        in
        subject :: terms, conditions @ binding.conditions, binding.bound
  in
  List.mapi (fun position exp -> position, exp) inputs
  |> List.fold_left step ([], [], bound)
  |> fun (terms, conditions, bound) ->
       List.rev terms, conditions, bound

let has_else prems =
  let found = ref false in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_prem prem =
      match prem.it with ElsePr -> found := true | _ -> ()
  end)
  in
  Visitor.list Visitor.prem prems;
  !found

let eq_conditions conditions =
  List.map
    (function
      | EqCondition condition -> condition
      | RewriteCond _ ->
          invalid_arg "an equation relation cannot use a rewrite condition")
    conditions

let translate_rule ?request_output index id params policy rule =
  match rule.it with
  | RuleD (_, quants, mixop, exp, prems) ->
      if has_else prems then
        invalid_arg "ElsePr in a relation rule requires source complement lowering";
      let exps = Prem.components mixop exp in
      let inputs, outputs =
        match policy with
        | Prescan.Execution {input_count; _}
        | Prescan.Equation {input_count} -> Prem.split input_count exps
        | Prescan.Predicate | Prescan.Builtin -> exps, []
      in
      let input_terms, head_conditions, bound =
        translate_inputs index params inputs
      in
      let left =
        App
          ( Prescan.rel_name index id
          , Param.translate_terms index params @ input_terms
          )
      in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements bound)
          ~bind_membership:(match policy with Prescan.Execution _ -> true | _ -> false)
          ?request_output
          prems
      in
      if not (List.for_all (Prem.known premises.bound) outputs) then
        invalid_arg "relation output contains an unbound variable";
      let conditions =
        head_conditions @ premises.conditions
        @ List.map
            (fun condition -> EqCondition condition)
            (Param.translate_eq_conditions index quants)
      in
      match policy with
      | Prescan.Execution _ ->
          let right =
            Prem.tuple outputs (List.map (Term.translate_exp index) outputs)
          in
          begin match conditions with
          | [] -> Rl (None, left, right)
          | _ -> Crl (None, left, right, conditions)
          end
      | Prescan.Equation _ ->
          let right =
            Prem.tuple outputs (List.map (Term.translate_exp index) outputs)
          in
          begin match eq_conditions conditions with
          | [] -> Eq (left, right, [])
          | conditions -> Ceq (left, right, conditions, [])
          end
      | Prescan.Predicate ->
          begin match eq_conditions conditions with
          | [] -> Eq (left, Const "true", [])
          | conditions -> Ceq (left, Const "true", conditions, [])
          end
      | Prescan.Builtin ->
          invalid_arg "builtin relation rules are supplied by builtins.maude"

let translate_decl index id params typ policy =
  let types = component_types typ in
  let parameter_sorts = Param.translate_sorts index params in
  match policy with
  | Prescan.Execution {request_sort; input_count} ->
      let inputs, outputs = Prem.split input_count types in
      let result_sort = output_sort index outputs in
      [ SortDecl request_sort
      ; SubsortDecl (result_sort, request_sort)
      ; OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) inputs
          ; codomain = request_sort
          ; arrow = Total
          ; attrs = frozen_all (List.length params + List.length inputs)
          }
      ]
  | Prescan.Equation {input_count} ->
      let inputs, outputs = Prem.split input_count types in
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) inputs
          ; codomain = output_sort index outputs
          ; arrow = Partial
          ; attrs = []
          }
      ]
  | Prescan.Predicate ->
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) types
          ; codomain = "Bool"
          ; arrow = Partial
          ; attrs = []
          }
      ]
  | Prescan.Builtin ->
      [ OpDecl
          { name = Prescan.rel_name index id
          ; domain = parameter_sorts @ List.map (Term.translate_sort index) types
          ; codomain = "Bool"
          ; arrow = Total
          ; attrs = []
          }
      ]

let translate ?request_output index id params _mixop typ rules =
  match Prescan.relation_policy index id with
  | Error _ -> []
  | Ok policy ->
      let declarations = translate_decl index id params typ policy in
      match policy with
      | Prescan.Builtin -> declarations
      | Prescan.Execution _ | Prescan.Equation _ | Prescan.Predicate ->
          declarations
          @ List.map
              (translate_rule ?request_output index id params policy)
              rules
