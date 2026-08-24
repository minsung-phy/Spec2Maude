open Util.Source
open Il.Ast
open Maude_il


let has_hint index id name =
  Prescan.has_dec_hint index id name

(* DecD declaration *)
let translate_decl index id params result_typ =
  OpDecl
    { name = Prescan.def_name index id
    ; domain = Param.translate_sorts index params
    ; codomain = Term.translate_sort index result_typ
    ; arrow =
        if has_hint index id "partial" then Partial
        else Total
    ; attrs = []
    }

let frozen_all count =
  match List.init count (( + ) 1) with
  | [] -> []
  | positions -> [Frozen positions]

let translate_request_header index id params result_typ =
  let result_sort = Term.translate_sort index result_typ in
  let request_sort = Prescan.rewrite_sort index id in
  [ SortDecl request_sort
  ; SubsortDecl (result_sort, request_sort)
  ; OpDecl
      { name = Prescan.def_name index id
      ; domain = Param.translate_sorts index params
      ; codomain = request_sort
      ; arrow = if has_hint index id "partial" then Partial else Total
      ; attrs = frozen_all (List.length params)
      }
  ]

let equation left right conditions attrs =
  match conditions with
  | [] -> Eq (left, right, attrs)
  | _ -> Ceq (left, right, conditions, attrs)


(* Variables determined by the head are bound by its term or conditions. *)
let head_bound args =
  Frontend.Det.(det_list det_arg args).varid

(* DecD equations cannot contain Maude rewrite conditions. *)
let eq_condition = function
  | EqCondition condition ->
      condition

  | RewriteCond _ ->
      invalid_arg
        "DecD with a rewrite premise requires source-directed rule lowering"

type clause_head =
  { term : term
  ; conditions : eq_condition list
  ; bound : Il.Free.Set.t
  }

let has_iteration exp =
  let found = ref false in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_exp exp =
      match exp.it with IterE _ -> found := true | _ -> ()
  end)
  in
  Visitor.exp exp;
  !found

let translate_head index id args =
  let step (terms, conditions, bound) (position, arg) =
    match arg.it with
    | ExpA exp when has_iteration exp ->
        begin match Prem.translate_pattern_parts index exp with
        | Some (pattern, guards) ->
            let subject =
              Var
                (generated_variable
                   ("DEF-ARG" ^ string_of_int (position + 1))
                   (Term.translate_sort index exp.note))
            in
            subject :: terms,
            conditions @ (MatchCond (pattern, subject) :: guards),
            Prem.bind bound exp
        | None ->
            Term.translate_exp index exp :: terms,
            conditions,
            Prem.bind bound exp
        end
    | ExpA exp ->
        begin match Prem.translate_pattern_parts index exp with
        | Some (pattern, guards) ->
            pattern :: terms, conditions @ guards, Prem.bind bound exp
        | None ->
            Term.translate_exp index exp :: terms,
            conditions,
            Prem.bind bound exp
        end
    | TypA _ | DefA _ | GramA _ ->
        Term.translate_arg index arg :: terms, conditions, bound
  in
  let terms, conditions, bound =
    List.mapi (fun position arg -> position, arg) args
    |> List.fold_left step ([], [], Il.Free.Set.empty)
  in
  let expected = head_bound args in
  if not (Il.Free.Set.subset expected bound) then
    invalid_arg "definition head does not bind every deterministic variable";
  { term = App (Prescan.def_name index id, List.rev terms)
  ; conditions
  ; bound
  }

let clause_has_rewrite_call index args rhs prems =
  List.exists (Prem.arg_has_rewrite_call index) args
  || Prem.has_rewrite_call index rhs
  || List.exists (Prem.prem_has_rewrite_call index) prems


(* Ordinary DefD clause *)
let translate_equation_clause index id clause =
  match clause.it with
  | DefD (quants, args, rhs, prems) ->
      if clause_has_rewrite_call index args rhs prems then
        invalid_arg
          "DecD calls a maude_rule definition without hint(maude_rule)";
      let head = translate_head index id args in

      let right =
        Term.translate_exp index rhs
      in

      let premises =
        Prem.translate_all
          index
          ~bound:(Il.Free.Set.elements head.bound)
          prems
      in

      let conditions =
        head.conditions
        @ List.map eq_condition premises.conditions
        @ Param.translate_eq_conditions index quants
      in

      let attrs =
        if premises.otherwise then [Owise]
        else []
      in

      equation head.term right conditions attrs

let choice_helper index id result_typ
    (choice : Prescan.membership_choice) rhs =
  match choice.element.it with
  | VarE _ ->
      let helper argument = App (choice.helper_name, [argument]) in
      let result_sort = Term.translate_sort index result_typ in
      let request_sort = Prescan.rewrite_sort index id in
      let rest = generated_variable "CHOICE-REST" "SpectecTerminals" in
      let head = generated_variable "CHOICE-HEAD" "SpectecTerminal" in
      let result = generated_variable "CHOICE-RESULT" result_sort in
      let selected = Term.translate_exp index choice.element in
      let selected_head =
        Term.as_sequence_element choice.element.note selected
      in
      [ OpDecl
          { name = choice.helper_name
          ; domain = ["SpectecTerminals"]
          ; codomain = request_sort
          ; arrow = Total
          ; attrs = [Frozen [1]]
          }
      ; Rl
          ( None
          , helper (Term.sequence [selected_head; Var rest])
          , Term.translate_exp index rhs
          )
      ; Crl
          ( None
          , helper (Term.sequence [Var head; Var rest])
          , Var result
          , [RewriteCond (helper (Var rest), Var result)]
          )
      ]
  | _ ->
      invalid_arg "membership choice element must be a variable"

let choice_public_quants element quants =
  match element.it with
  | VarE selected ->
      let selected_quants, public_quants =
        List.partition
          (fun quant ->
            match quant.it with
            | ExpP (id, _) -> id.it = selected.it
            | TypP _ | DefP _ | GramP _ -> false)
          quants
      in
      begin match selected_quants with
      | [_] -> public_quants
      | [] ->
          invalid_arg "membership choice variable has no ExpP quantifier"
      | _ ->
          invalid_arg "membership choice variable has multiple ExpP quantifiers"
      end
  | _ ->
      invalid_arg "membership choice element must be a variable"

let translate_choice_clause index id result_typ
    (choice : Prescan.membership_choice) clause =
  match clause.it with
  | DefD (quants, args, rhs, _) ->
      if clause_has_rewrite_call index args rhs choice.prefix then
        invalid_arg
          "membership choice prefix cannot call a rewrite definition";
      let head = translate_head index id args in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements head.bound) choice.prefix
      in
      if premises.otherwise then
        invalid_arg "membership choice cannot follow ElsePr";
      if Prem.known premises.bound choice.element then
        invalid_arg "membership choice element is already bound";
      if not (Prem.known premises.bound choice.collection) then
        invalid_arg "membership choice collection is unbound";
      let right =
        App
          ( choice.helper_name
          , [Term.translate_exp index choice.collection]
          )
      in
      let conditions =
        head.conditions
        @ List.map eq_condition premises.conditions
        @ Param.translate_eq_conditions index
            (choice_public_quants choice.element quants)
      in
      equation head.term right conditions []
      :: choice_helper index id result_typ choice rhs

let translate_clause index id result_typ clause =
  match Prescan.membership_choice index clause with
  | Some choice ->
      translate_choice_clause index id result_typ choice clause
  | None ->
      [translate_equation_clause index id clause]

let translate_rule_clause index id clause =
  match clause.it with
  | DefD (quants, args, rhs, prems) ->
      if List.exists (Prem.arg_has_rewrite_call index) args
         || Prem.has_rewrite_call index rhs
      then
        invalid_arg
          "maude_rule calls are only supported as premise equalities";
      let head = translate_head index id args in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements head.bound) prems
      in
      if premises.otherwise then
        invalid_arg "ElsePr is not supported in a maude_rule DecD";
      let conditions =
        List.map (fun condition -> EqCondition condition) head.conditions
        @ premises.conditions
        @ List.map
            (fun condition -> EqCondition condition)
            (Param.translate_eq_conditions index quants)
      in
      let right = Term.translate_exp index rhs in
      match conditions with
      | [] -> Rl (None, head.term, right)
      | _ -> Crl (None, head.term, right, conditions)


(* Complete DecD *)
let translate index id params result_typ clauses =
  let builtin = has_hint index id "builtin" in
  let choice = Prescan.has_membership_choice index id in
  let rule = has_hint index id "maude_rule" in
  if not builtin && choice && rule then
    invalid_arg "membership choice conflicts with hint(maude_rule)";
  let header =
    if builtin then [translate_decl index id params result_typ]
    else if choice || rule then translate_request_header index id params result_typ
    else [translate_decl index id params result_typ]
  in
  if builtin || not (Prescan.definition_body_supported index id) then
    header
  else if choice then
    header @ List.concat_map (translate_clause index id result_typ) clauses
  else if rule then
    header @ List.map (translate_rule_clause index id) clauses
  else
    header @ List.map (translate_equation_clause index id) clauses
