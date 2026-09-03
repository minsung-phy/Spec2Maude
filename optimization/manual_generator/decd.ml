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
        if has_hint index id "maude_kind" then Partial
        else Total
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

let translate_head index id params args =
  let step (terms, conditions, bound) (position, arg) =
    match arg.it with
    | ExpA exp ->
        let expected_exp =
          match exp.it, List.nth_opt params position with
          | (ListE _ | CatE _), Some {it = ExpP (_, formal_typ); _} ->
              {exp with note = formal_typ}
          | _ -> exp
          (* Empty and concatenated list patterns need the formal list sort;
             ordinary variables keep their elaborated note so prescanned
             source-variable identities remain stable. *)
        in
        begin match Prem.translate_pattern_parts index expected_exp with
        | Some (pattern, guards) ->
            pattern :: terms, conditions @ guards, Prem.bind bound exp
        | None ->
            let subject =
              Var
                (generated_variable
                   ("DEF-ARG" ^ string_of_int (position + 1))
                   (Term.translate_sort index expected_exp.note))
            in
            let binding =
              Prem.bind_pattern index bound expected_exp subject
                "definition head is not a structural pattern"
            in
            subject :: terms,
            conditions @ List.map eq_condition binding.conditions,
            binding.bound
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

let add_variable variables variable =
  if List.exists (same_variable variable) variables then variables
  else variable :: variables

let rec term_variables variables = function
  | Var variable -> add_variable variables variable
  | Const _ -> variables
  | App (_, args) -> List.fold_left term_variables variables args

let variables_bound bound term =
  term_variables [] term
  |> List.for_all (fun variable -> List.exists (same_variable variable) bound)

let condition_ready bound = function
  | EqCond (left, right) ->
      variables_bound bound left && variables_bound bound right
  | MatchCond (_, subject) -> variables_bound bound subject
  | MembershipCond (term, _) | BoolCond term -> variables_bound bound term

let condition_binds bound = function
  | MatchCond (pattern, _) -> not (variables_bound bound pattern)
  | EqCond _ | MembershipCond _ | BoolCond _ -> false

let take_ready select bound conditions =
  let rec take prefix = function
    | [] -> None
    | condition :: rest
      when select condition && condition_ready bound condition ->
        Some (condition, List.rev_append prefix rest)
    | condition :: rest -> take (condition :: prefix) rest
  in
  take [] conditions

(* Check ready guards before constructing a deferred result pattern. *)
let schedule_conditions left conditions =
  let rec schedule bound ordered pending =
    match pending with
    | [] -> List.rev ordered
    | _ ->
        let selected =
          match
            take_ready
              (fun condition -> not (condition_binds bound condition))
              bound pending
          with
          | Some selected -> Some selected
          | None -> take_ready (fun _ -> true) bound pending
        in
        begin match selected with
        | None ->
            invalid_arg "definition conditions have unresolved dependencies"
        | Some (MatchCond (pattern, subject), pending)
          when variables_bound bound pattern ->
            schedule bound (EqCond (pattern, subject) :: ordered) pending
        | Some ((MatchCond (pattern, _) as condition), pending) ->
            schedule (term_variables bound pattern) (condition :: ordered) pending
        | Some ((EqCond _ | MembershipCond _ | BoolCond _ as condition), pending) ->
            schedule bound (condition :: ordered) pending
        end
  in
  schedule (term_variables [] left) [] conditions

let rec contains_sequence = function
  | App ("_ _", _) -> true
  | App (_, args) -> List.exists contains_sequence args
  | Var _ | Const _ -> false

let rec heads_may_overlap left right =
  if contains_sequence left || contains_sequence right then true
  else
    match left, right with
    | Var _, _ | _, Var _ -> true
    | Const left, Const right -> left = right
    | App (left, left_args), App (right, right_args) ->
        left = right
        && List.length left_args = List.length right_args
        && List.for_all2 heads_may_overlap left_args right_args
    | Const _, App _ | App _, Const _ -> false

type prepared_clause =
  { clause : clause
  ; head : clause_head
  ; head_proven : Il.Free.Set.t
  }

let quantified_type quants id =
  match
    List.filter_map
      (fun quant ->
        match quant.it with
        | ExpP (quant_id, typ) when quant_id.it = id.it -> Some typ
        | ExpP _ | TypP _ | DefP _ | GramP _ -> None)
      quants
  with
  | [typ] -> Some typ
  | [] | _ :: _ :: _ -> None

let direct_formal_variable formal_typ position clause =
  match clause.it with
  | DefD (quants, args, _, _) ->
      begin match List.nth_opt args position with
      | Some {it = ExpA {it = VarE id; _}; _} ->
          begin match quantified_type quants id with
          | Some typ when Il.Eq.eq_typ typ formal_typ -> Some id
          | Some _ | None -> None
          end
      | Some {it = ExpA _ | TypA _ | DefA _ | GramA _; _} | None -> None
      end

let signature_proven params current peers =
  List.mapi
    (fun position formal -> position, formal)
    params
  |> List.fold_left
       (fun proven (position, formal) ->
         match formal.it with
         | ExpP (_, formal_typ) ->
             begin match
               direct_formal_variable formal_typ position current
             with
             | Some id when
                 List.for_all
                   (fun peer ->
                     Option.is_some
                       (direct_formal_variable formal_typ position peer))
                   peers ->
                 Il.Free.Set.add id.it proven
             | Some _ | None -> proven
             end
         | TypP _ | DefP _ | GramP _ -> proven)
       Il.Free.Set.empty

let exact_variable quants expected exp =
  match exp.it with
  | VarE id ->
      begin match quantified_type quants id with
      | Some typ when Il.Eq.eq_typ typ expected ->
          Il.Free.Set.singleton id.it
      | Some _ | None -> Il.Free.Set.empty
      end
  | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _ | TupE _
  | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _ | DotE _
  | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _
  | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _ | CvtE _
  | SubE _ ->
      Il.Free.Set.empty

let rec list_pattern_proven index quants expected exp =
  match expected.it, exp.it with
  | IterT (_, List), CatE (left, right) ->
      Il.Free.Set.union
        (list_pattern_proven index quants expected left)
        (list_pattern_proven index quants expected right)
  | IterT (element, List), ListE elements ->
      List.fold_left
        (fun proven element_pattern ->
          Il.Free.Set.union proven
            (list_pattern_proven index quants element element_pattern))
        Il.Free.Set.empty elements
  | IterT (_, List), IterE (body, iterexp) ->
      begin match Iter.identity_source index body iterexp with
      | Some ({it = VarE _; _} as source) ->
          exact_variable quants expected source
      | Some _ | None -> Il.Free.Set.empty
      end
  | _, VarE _ -> exact_variable quants expected exp
  | IterT (_, (Opt | List1 | ListN _)), _
  | (VarT _ | BoolT | NumT _ | TextT | TupT _ | IterT _), _ ->
      Il.Free.Set.empty

let list_components_proven index params clause =
  let abstract_types =
    List.fold_left
      (fun types param ->
        match param.it with
        | TypP id -> Il.Free.Set.add id.it types
        | ExpP _ | DefP _ | GramP _ -> types)
      Il.Free.Set.empty params
  in
  match clause.it with
  | DefD (quants, args, _, _) ->
      List.mapi (fun position formal -> position, formal) params
      |> List.fold_left
           (fun proven (position, formal) ->
             match formal.it, List.nth_opt args position with
             | ExpP (_, ({it = IterT (element, List); _} as formal_typ)),
               Some {it = ExpA actual; _} ->
                 if
                   not (Prescan.alias_type index element)
                   && Il.Free.Set.disjoint abstract_types
                        Il.Free.(free_typ element).typid
                 then
                   Il.Free.Set.union proven
                     (list_pattern_proven index quants formal_typ actual)
                 else proven
             | (ExpP _ | TypP _ | DefP _ | GramP _), _ -> proven)
           Il.Free.Set.empty

let prepare_clauses index id params clauses =
  let prepared =
    List.map
      (fun clause ->
        let args = match clause.it with DefD (_, args, _, _) -> args in
        clause, translate_head index id params args)
      clauses
  in
  List.mapi
    (fun position (clause, head) ->
      let overlapping =
        List.mapi (fun other item -> other, item) prepared
        |> List.filter_map (fun (other, (peer, peer_head)) ->
             if position <> other && heads_may_overlap head.term peer_head.term
             then Some peer
             else None)
      in
      let head_proven =
        if overlapping = [] then head.bound
        else
          Il.Free.Set.union
            (signature_proven params clause overlapping)
            (list_components_proven index params clause)
      in
      {clause; head; head_proven})
    prepared

let proven_variables prepared premises =
  (* Valid ingress proves variables selected by a unique head or shared formal
     signature; a successful premise proves the variables that it introduced. *)
  let introduced =
    Il.Free.Set.diff premises.Prem.bound prepared.head.bound
  in
  Il.Free.Set.union prepared.head_proven introduced

let clause_has_rewrite_call index args rhs prems =
  List.exists (Prem.arg_has_rewrite_call index) args
  || Prem.has_rewrite_call index rhs
  || List.exists (Prem.prem_has_rewrite_call index) prems


(* Ordinary DefD clause *)
let translate_equation_clause index prepared =
  match prepared.clause.it with
  | DefD (quants, args, rhs, prems) ->
      if clause_has_rewrite_call index args rhs prems then
        invalid_arg
          "DecD calls a maude_rule definition without hint(maude_rule)";
      let head = prepared.head in

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
        @ Param.translate_eq_conditions
            ~proven:(proven_variables prepared premises) index quants
        |> schedule_conditions head.term
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
      let collection_sort =
        Term.translate_sort index choice.collection.note
        |> Term.sequence_tail_sort
      in
      let element_sort = Term.translate_sort index choice.element.note in
      let rest = generated_variable "CHOICE-REST" collection_sort in
      let head = generated_variable "CHOICE-HEAD" element_sort in
      let result = generated_variable "CHOICE-RESULT" result_sort in
      let selected = Term.translate_exp index choice.element in
      let selected_head =
        Term.as_sequence_element index choice.element.note selected
      in
      [ OpDecl
          { name = choice.helper_name
          ; domain = [collection_sort]
          ; codomain = request_sort
          ; arrow = Total
          ; attrs = [Frozen [1]]
          }
      ; Rl
          ( Some (choice.helper_name ^ "-found")
          , helper
              (Term.sequence_for_sort collection_sort [selected_head; Var rest])
          , Term.translate_exp index rhs
          )
      ; Crl
          ( Some (choice.helper_name ^ "-next")
          , helper
              (Term.sequence_for_sort collection_sort [Var head; Var rest])
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
    (choice : Prescan.membership_choice) prepared =
  match prepared.clause.it with
  | DefD (quants, args, rhs, _) ->
      if clause_has_rewrite_call index args rhs choice.prefix then
        invalid_arg
          "membership choice prefix cannot call a rewrite definition";
      let head = prepared.head in
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
            ~proven:(proven_variables prepared premises)
            (choice_public_quants choice.element quants)
        |> schedule_conditions head.term
      in
      equation head.term right conditions []
      :: choice_helper index id result_typ choice rhs

let translate_clause index id result_typ prepared =
  match Prescan.membership_choice index prepared.clause with
  | Some choice ->
      translate_choice_clause index id result_typ choice prepared
  | None ->
      [translate_equation_clause index prepared]

let translate_rule_clause index id ordinal prepared =
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
          ~bound:(Il.Free.Set.elements head.bound) prems
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
      let right = Term.translate_exp index rhs in
      let label =
        Some
          ("def-" ^ String.lowercase_ascii (Prescan.sanitize id.it)
           ^ "-" ^ string_of_int (ordinal + 1))
      in
      match conditions with
      | [] -> Rl (label, head.term, right)
      | _ -> Crl (label, head.term, right, conditions)


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
      header @ List.concat_map (translate_clause index id result_typ) clauses
    else if rule then
      header
      @ List.mapi (fun ordinal clause ->
          translate_rule_clause index id ordinal clause) clauses
    else
      header @ List.map (translate_equation_clause index) clauses
