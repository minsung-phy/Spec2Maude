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
    ; arrow = if has_hint index id "maude_kind" then Partial else Total
    ; attrs = []
    }

let translate_request_header index id params result_typ =
  let result_sort = Term.translate_sort index result_typ in
  let request_sort = Prescan.rewrite_sort index id in
  [ SortDecl request_sort
  ; SubsortDecl (result_sort, request_sort)
  ; OpDecl
      { name = Prescan.def_name index id
      ; domain = Param.translate_sorts index params
      ; codomain = request_sort
      ; arrow = if has_hint index id "maude_kind" then Partial else Total
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

let translate_head index id args =
  let sorts, _ = Term.definition_sorts index id in
  let step (terms, conditions, bound) (position, arg) =
    let sort = List.nth sorts position in
    match arg.it with
    | ExpA exp ->
        let term, guards, bound =
          Prem.bind_head_argument index bound
            ("DEF-ARG" ^ string_of_int (position + 1))
            "definition head is not a structural pattern" exp
        in
        Term.to_parameter_sort index sort exp term :: terms,
        conditions @ List.map eq_condition guards, bound
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

type prepared_clause =
  { clause : clause
  ; head : clause_head
  ; head_proven : Il.Free.Set.t
  ; result_sort : sort
  ; index : Prescan.t
  }

(* A head SubE pattern already guards its variable, so the quantifier check
   of an equal membership repeats it. *)
let guarded_quants index quants args =
  let collector =
    { (Il.Walk.base_collector [] ( @ )) with
      collect_exp =
        (fun exp ->
          match exp.it with
          | SubE ({it = VarE id; _}, typ, _) -> [id.it, typ], true
          | _ -> [], true)
    }
  in
  let guards = List.concat_map (Il.Walk.collect_arg collector) args in
  List.fold_left
    (fun proven quant ->
      match quant.it with
      | ExpP (id, typ)
        when List.exists
               (fun (x, t) -> x = id.it && Term.same_membership index t typ)
               guards ->
          Il.Free.Set.add id.it proven
      | ExpP _ | TypP _ | DefP _ | GramP _ -> proven)
    Il.Free.Set.empty quants

let prepare_clauses index id params clauses =
  List.map
    (fun clause ->
      match clause.it with
      | DefD (quants, args, _, _) ->
          let index = Term.with_parameter_types index params args in
          let head = translate_head index id args in
          let head_proven = guarded_quants index quants args in
          let _, result_sort = Term.definition_sorts index id in
          {clause; head; head_proven; result_sort; index})
    clauses

let proven_variables prepared premises =
  (* A successful premise proves the variables that it introduced. *)
  let introduced =
    Il.Free.Set.diff premises.Prem.bound prepared.head.bound
  in
  Il.Free.Set.union prepared.head_proven introduced

let clause_has_rewrite_call index args rhs prems =
  List.exists (Prem.arg_has_rewrite_call index) args
  || Prem.has_rewrite_call index rhs
  || List.exists (Prem.prem_has_rewrite_call index) prems


let translate_result prepared rhs =
  let index = prepared.index in
  Term.to_sort index ~sort:prepared.result_sort rhs.note
    (Term.translate_exp index rhs)

(* Ordinary DefD clause *)
let translate_equation_clause prepared =
  let index = prepared.index in
  match prepared.clause.it with
  | DefD (quants, args, rhs, prems) ->
      if clause_has_rewrite_call index args rhs prems then
        invalid_arg
          "DecD calls a maude_rule definition without hint(maude_rule)";
      let head = prepared.head in

      let right = translate_result prepared rhs in

      let premises =
        Prem.translate_all
          index
          ~bound:(Il.Free.Set.elements head.bound)
          ~bind_membership:false ~collect_outputs:false
          prems
      in

      let conditions =
        head.conditions
        @ List.map eq_condition premises.conditions
        @ Param.translate_eq_conditions
            ~proven:(proven_variables prepared premises) index quants
        |> schedule_equation_conditions head.term
      in

      let attrs =
        if premises.otherwise then [Owise]
        else []
      in

      equation head.term right conditions attrs

let choice_helper index id
    (choice : Prescan.membership_choice) rhs =
  match choice.element.it with
  | VarE _ ->
      let helper argument = App (choice.helper_name, [argument]) in
      let request_sort = Prescan.rewrite_sort index id in
      let representation =
        Prescan.sequence_representation index choice.collection.note
      in
      let rest = generated_variable "CHOICE-REST" representation.sort in
      let prefix = generated_variable "CHOICE-PREFIX" representation.sort in
      let selected = Term.translate_exp index choice.element in
      let selected_head =
        Term.as_sequence_element index choice.element.note selected
      in
      [ OpDecl
          { name = choice.helper_name
          ; domain = [representation.sort]
          ; codomain = request_sort
          ; arrow = Total
          ; attrs = [Frozen [1]]
          }
      ; Rl
          ( None
          , helper
              (Term.sequence_of_typ index choice.collection.note
                 [Var prefix; selected_head; Var rest])
          , Term.translate_exp index rhs
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

let translate_choice_clause id
    (choice : Prescan.membership_choice) prepared =
  let index = prepared.index in
  match prepared.clause.it with
  | DefD (quants, args, rhs, _) ->
      if clause_has_rewrite_call index args rhs choice.prefix then
        invalid_arg
          "membership choice prefix cannot call a rewrite definition";
      let head = prepared.head in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements head.bound)
          ~bind_membership:false ~collect_outputs:false
          choice.prefix
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
            ~proven:(proven_variables prepared premises)
            (choice_public_quants choice.element quants)
        |> schedule_equation_conditions head.term
      in
      equation head.term right conditions []
      :: choice_helper index id choice rhs

let translate_clause index id prepared =
  match Prescan.membership_choice index prepared.clause with
  | Some choice ->
      translate_choice_clause id choice prepared
  | None ->
      [translate_equation_clause prepared]

let translate_rule_clause prepared =
  let index = prepared.index in
  match prepared.clause.it with
  | DefD (quants, args, rhs, prems) ->
      if List.exists (Prem.arg_has_rewrite_call index) args
         || Prem.has_rewrite_call index rhs
      then
        invalid_arg
          "maude_rule calls are only supported as premise equalities";
      let head = prepared.head in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements head.bound)
          ~bind_membership:false ~collect_outputs:false prems
      in
      if premises.otherwise then
        invalid_arg "ElsePr is not supported in a maude_rule DecD";
      let conditions =
        List.map (fun condition -> EqCondition condition) head.conditions
        @ premises.conditions
        @ List.map
            (fun condition -> EqCondition condition)
            (Param.translate_eq_conditions
               ~proven:(proven_variables prepared premises) index quants)
      in
      let right = translate_result prepared rhs in
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
  else
    let clauses = prepare_clauses index id params clauses in
    if choice then
      header @ List.concat_map (translate_clause index id) clauses
    else if rule then
      header @ List.map translate_rule_clause clauses
    else
      header @ List.map translate_equation_clause clauses


(* Def-parameter specialization: a copy of a DecD whose DefP parameters are
 * fixed to declared definitions, following the source meaning
 * $g_t(xs) = $g(xs) with f := t. *)

type specialization =
  { callee : id
  ; targets : id list  (* one per DefP parameter, in parameter order *)
  ; copy : id
  }

(* Def ids have no binders inside clauses, so renaming a def parameter is
 * capture-free; Il.Subst would also refresh iteration binders. *)
let renaming ids targets =
  let rename id =
    match List.assoc_opt id.it (List.combine ids targets) with
    | Some target -> target
    | None -> id
  in
  {Il.Walk.base_transformer with transform_def_id = rename}

let specialize_clause id params targets clause =
  let DefD (quants, args, exp, prems) = clause.it in
  let args, def_args = Param.split_def_positions params args in
  let ids =
    List.map
      (fun arg ->
        match arg.it with
        | DefA def_id -> def_id.it
        | ExpA _ | TypA _ | GramA _ ->
            Util.Error.error arg.at "translation"
              ("Unsupported DefD argument in DecD $" ^ id.it
               ^ ": a def parameter position expects a DefA argument"))
      def_args
  in
  let quants =
    List.filter
      (fun quant ->
        match quant.it with
        | DefP (def_id, _, _) -> not (List.mem def_id.it ids)
        | ExpP _ | TypP _ | GramP _ -> true)
      quants
  in
  Il.Walk.transform_clause (renaming ids targets)
    (DefD (quants, args, exp, prems) $ clause.at)

let specialize specialization id params result_typ clauses =
  let kept, def_params = Param.split_def_positions params params in
  let rename = renaming (Param.def_ids def_params) specialization.targets in
  DecD
    ( specialization.copy
    , List.map (Il.Walk.transform_param rename) kept
    , Il.Walk.transform_typ rename result_typ
    , List.map (specialize_clause id params specialization.targets) clauses )
