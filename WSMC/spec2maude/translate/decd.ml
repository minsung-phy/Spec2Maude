open Util.Source
open Il.Ast
open Maude_il


let has_hint index id name =
  Prescan.hints index
  |> List.exists (fun hintdef ->
       match hintdef.it with
       | DecH (target, hints) ->
           target.it = id.it
           && List.exists
                (fun (hint : hint) -> hint.hintid.it = name)
                hints
       | _ ->
           false)


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


(* DefD clause *)
let translate_clause index id clause =
  match clause.it with
  | DefD (quants, args, rhs, prems) ->
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


(* Complete DecD *)
let translate index id params result_typ clauses =
  translate_decl index id params result_typ
  :: List.map (translate_clause index id) clauses
