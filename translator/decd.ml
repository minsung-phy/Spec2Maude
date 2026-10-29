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

(* DefD clauses are a sequential pattern match (Bringing the WebAssembly
   Standard up to Speed with SpecTec, 3): a clause applies only if no earlier
   clause does. Equations are unordered, so a clause carries the complement of
   each earlier clause that its head can match:
     def $inv_jsize(8) = I8   def $inv_jsize(n) = $inv_isize(n)
     ceq inv-jsize(N) = inv-isize(N) if N =/= 8 .
   One head must be an instance of the other, the extra structure of an earlier
   head ground; the earlier conditions must be negatable. Otherwise
   Unsupported. *)
let complement at (head, _, _, _) (earlier_head, _, earlier_conditions, _) =
  let rec instance bindings pattern subject =
    match pattern, subject with
    | Var variable, _ ->
        begin match List.find_opt (fun (v, _) -> same_variable v variable) bindings with
        | Some (_, previous) when Reld.same_term previous subject -> Some bindings
        | Some _ -> None
        | None -> Some ((variable, subject) :: bindings)
        end
    | Const left, Const right when left = right -> Some bindings
    | App (left, lefts), App (right, rights)
      when left = right && List.length lefts = List.length rights ->
        List.fold_left2
          (fun bindings pattern subject ->
            Option.bind bindings (fun bindings -> instance bindings pattern subject))
          (Some bindings) lefts rights
    | _ -> None
  in
  let unsupported reason =
    Util.Error.error at "translation"
      ("Unsupported: DefD clause order: " ^ reason)
  in
  (* The earlier variables in terms of this clause's input, and the
     disequalities for the earlier head's extra ground structure. *)
  let substitution, differences =
    match instance [] head earlier_head, instance [] earlier_head head with
    | Some bindings, _ ->
        (* A variable repeated in the earlier head, f(X, X) against f(A, B),
           requires A = B. *)
        let rec repeated = function
          | (variable, Var earlier) :: rest ->
              List.filter_map
                (function
                  | other, Var earlier' when same_variable earlier earlier' ->
                      Some (App ("_=/=_", [Var variable; Var other]))
                  | _ -> None)
                rest
              @ repeated rest
          | _ :: rest -> repeated rest
          | [] -> []
        in
        let repeated = repeated bindings in
        ( List.filter_map
            (function variable, Var earlier -> Some (earlier, Var variable) | _ -> None)
            bindings
        , repeated
          @ List.filter_map
              (function
                | _, Var _ -> None
                | variable, subject when term_variables [] subject = [] ->
                    Some (App ("_=/=_", [Var variable; subject]))
                | _ -> unsupported "an earlier head has non-ground extra structure")
              bindings )
    | None, Some bindings -> bindings, []
    | None, None -> unsupported "an earlier clause overlaps without being an instance"
  in
  let condition_variables variables = function
    | EqCond (left, right) | MatchCond (left, right) ->
        term_variables (term_variables variables left) right
    | MembershipCond (term, _) | BoolCond term -> term_variables variables term
  in
  let known variable =
    List.exists (fun (v, _) -> same_variable v variable) substitution
  in
  if not (List.for_all known
            (List.fold_left condition_variables [] earlier_conditions)) then
    unsupported "an earlier clause's conditions use variables outside its head";
  let substitute term =
    let rec go = function
      | Var variable as term ->
          begin match List.find_opt (fun (v, _) -> same_variable v variable) substitution with
          | Some (_, replacement) -> replacement
          | None -> term
          end
      | Const _ as term -> term
      | App (name, args) -> App (name, List.map go args)
    in
    go term
  in
  let negated =
    List.map
      (function
        | BoolCond predicate -> Reld.negate_comparison (substitute predicate)
        | EqCond (left, right) -> App ("_=/=_", [substitute left; substitute right])
        | MatchCond _ | MembershipCond _ ->
            unsupported "an earlier clause binds in its conditions")
      earlier_conditions
  in
  BoolCond
    (List.fold_left (Reld.bool_combine "_or_" "false") (Const "false")
       (differences @ negated))

(* Ordinary DefD clause: head, result, conditions, attributes. *)
let equation_clause prepared =
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

      head.term, right, conditions, attrs

let translate_equation_clause prepared =
  let head, right, conditions, attrs = equation_clause prepared in
  equation head right conditions attrs

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


(* Equation clauses in source order, each with the complements of the earlier
   clauses that can match its input. An otherwise clause is [owise]. *)
let ordered_clauses index clauses =
  let arguments = function App (_, args) -> args | _ -> [] in
  let source_arguments prepared =
    match prepared.clause.it with DefD (_, args, _, _) -> args
  in
  (* As for ElsePr predecessors (Reld): the source patterns and the
     translated heads may both overlap. *)
  let overlap (prepared, (head, _, _, _)) (earlier, (earlier_head, _, _, _)) =
    List.for_all2
      (fun arg earlier_arg ->
        match arg.it, earlier_arg.it with
        | ExpA exp, ExpA earlier_exp -> Reld.source_overlap index exp earlier_exp
        | _ -> true)
      (source_arguments prepared) (source_arguments earlier)
    && Reld.inputs_may_overlap index (arguments head) (arguments earlier_head)
  in
  let step (earlier, statements) prepared =
    let (head, right, conditions, attrs) as current = equation_clause prepared in
    let complements =
      if List.mem Owise attrs then []
      else
        earlier
        |> List.filter (fun earlier -> overlap (prepared, current) earlier)
        |> List.map (fun (_, parts) -> complement prepared.clause.at current parts)
    in
    let conditions =
      if complements = [] then conditions
      else schedule_equation_conditions head (conditions @ complements)
    in
    earlier @ [prepared, current], statements @ [equation head right conditions attrs]
  in
  snd (List.fold_left step ([], []) clauses)

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
      header @ ordered_clauses index clauses


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
