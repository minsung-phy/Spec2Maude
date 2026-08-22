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

let translate_rule_header index id params result_typ =
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


(* Variables matched by the left-hand arguments are already bound. *)
let head_bound args =
  let det = Frontend.Det.det_list Frontend.Det.det_arg args in
  Il.Free.Set.elements det.varid


(* DecD equations cannot contain Maude rewrite conditions. *)
let eq_condition = function
  | EqCondition condition ->
      condition

  | RewriteCond _ ->
      invalid_arg
        "DecD with a rewrite premise requires source-directed rule lowering"

let clause_has_rewrite_call index args rhs prems =
  List.exists (Prem.arg_has_rewrite_call index) args
  || Prem.has_rewrite_call index rhs
  || List.exists (Prem.prem_has_rewrite_call index) prems


(* DefD clause *)
let translate_clause index id clause =
  match clause.it with
  | DefD (quants, args, rhs, prems) ->
      if clause_has_rewrite_call index args rhs prems then
        invalid_arg
          "DecD calls a maude_rule definition without hint(maude_rule)";
      let left =
        App
          ( Prescan.def_name index id
          , List.map (Term.translate_arg index) args
          )
      in

      let right =
        Term.translate_exp index rhs
      in

      let premises =
        Prem.translate_all
          index
          ~bound:(head_bound args)
          prems
      in

      let conditions =
        List.map eq_condition premises.conditions
        @ Param.translate_eq_conditions index quants
      in

      let attrs =
        if premises.otherwise then [Owise]
        else []
      in

      match conditions with
      | [] ->
          Eq (left, right, attrs)

      | _ ->
          Ceq (left, right, conditions, attrs)

let translate_rule_clause index id clause =
  match clause.it with
  | DefD (quants, args, rhs, prems) ->
      if List.exists (Prem.arg_has_rewrite_call index) args
         || Prem.has_rewrite_call index rhs
      then
        invalid_arg
          "maude_rule calls are only supported as premise equalities";
      let left =
        App
          ( Prescan.def_name index id
          , List.map (Term.translate_arg index) args
          )
      in
      let premises =
        Prem.translate_all index ~bound:(head_bound args) prems
      in
      if premises.otherwise then
        invalid_arg "ElsePr is not supported in a maude_rule DecD";
      let conditions =
        premises.conditions
        @ List.map
            (fun condition -> EqCondition condition)
            (Param.translate_eq_conditions index quants)
      in
      let right = Term.translate_exp index rhs in
      match conditions with
      | [] -> Rl (None, left, right)
      | _ -> Crl (None, left, right, conditions)


(* Complete DecD *)
let translate index id params result_typ clauses =
  if has_hint index id "builtin" then
    [translate_decl index id params result_typ]
  else if has_hint index id "maude_rule" then
    translate_rule_header index id params result_typ
    @ List.map (translate_rule_clause index id) clauses
  else
    translate_decl index id params result_typ
    :: List.map (translate_clause index id) clauses
