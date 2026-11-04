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
    ; arrow = if Prescan.is_partial_def index id then Partial else Total
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
      ; arrow = if Prescan.is_partial_def index id then Partial else Total
      ; attrs = frozen_all (List.length params)
      }
  ]


(* Variables determined by the head are bound by its term or conditions. *)
let head_bound args =
  Frontend.Det.(det_list det_arg args).varid

(* DecD equations cannot contain Maude rewrite conditions. *)
let eq_condition = function
  | EqCondition condition ->
      condition

  | RewriteCond _ ->
      raise (Unsupported
        "DecD with a rewrite premise requires source-directed rule lowering")

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
    raise (Unsupported "definition head does not bind every deterministic variable");
  { term = App (Prescan.def_name index id, List.rev terms)
  ; conditions
  ; bound
  }

type prepared_clause =
  { clause : clause
  ; head : clause_head
  ; head_proven : Il.Free.Set.t
  ; result_sort : sort
  ; map_result : bool  (* hint(maude_map) *)
  ; index : Prescan.t
  }

(* A head SubE pattern already guards its variable, so the quantifier check
   of an equal membership repeats it. *)
let guarded_quants index quants args =
  let guards = ref [] in
  let module Guards = Il.Iter.Make (struct
    include Il.Iter.Skip
    let visit_exp exp =
      match exp.it with
      | SubE ({it = VarE id; _}, typ, _) -> guards := (id.it, typ) :: !guards
      | _ -> ()
  end) in
  Guards.args args;
  let guards = !guards in
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

(* A clause that cannot be translated is Unsupported at that clause. *)
let located id clause f =
  Maude_il.located clause.at ("DecD " ^ id.it ^ " clause") f

let prepare_clauses index id params clauses =
  List.map
    (fun clause ->
      located id clause @@ fun () ->
      match clause.it with
      | DefD (quants, args, _, _) ->
          let index = Term.with_parameter_types index params args in
          let head = translate_head index id args in
          let head_proven = guarded_quants index quants args in
          let _, result_sort = Term.definition_sorts index id in
          let map_result = Prescan.map_definition index id in
          {clause; head; head_proven; result_sort; map_result; index})
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
  if prepared.map_result then
    (* A hint(maude_map) definition returns the map stored in a maude_map
       field. *)
    match Term.stored_value index rhs with
    | Some (Hintd.Map, map) -> map
    | Some (Hintd.Array, _) | None ->
        raise (Unsupported "a hint(maude_map) definition must return a maude_map field")
  else
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
  let unsupported reason =
    Util.Error.error at "translation"
      ("Unsupported: DefD clause order: " ^ reason)
  in
  (* The earlier variables in terms of this clause's input, and the
     disequalities for the earlier head's extra ground structure. *)
  let substitution, differences =
    match match_term [] head earlier_head, match_term [] earlier_head head with
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
  let known variable =
    List.exists (fun (v, _) -> same_variable v variable) substitution
  in
  if not (List.for_all known
            (List.fold_left eq_condition_variables [] earlier_conditions)) then
    unsupported "an earlier clause's conditions use variables outside its head";
  let substitute term =
    let rec go = function
      | Var variable as term ->
          begin match
            List.find_opt (fun (v, _) -> same_variable v variable) substitution
          with
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
        | MatchCond _ ->
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
        raise (Unsupported
          "DecD calls a maude_rule definition without hint(maude_rule)");
      let head = prepared.head in

      let right = translate_result prepared rhs in

      let premises =
        Prem.translate_all
          index
          ~bound:(Il.Free.Set.elements head.bound)
          ~bind_membership:false ~collect_outputs:true
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
  equation ~attrs head right conditions

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
      raise (Unsupported "membership choice element must be a variable")

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
          raise (Unsupported "membership choice variable has no ExpP quantifier")
      | _ ->
          raise (Unsupported "membership choice variable has multiple ExpP quantifiers")
      end
  | _ ->
      raise (Unsupported "membership choice element must be a variable")

let translate_choice_clause id
    (choice : Prescan.membership_choice) prepared =
  let index = prepared.index in
  match prepared.clause.it with
  | DefD (quants, args, rhs, _) ->
      if clause_has_rewrite_call index args rhs choice.prefix then
        raise (Unsupported
          "membership choice prefix cannot call a rewrite definition");
      let head = prepared.head in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements head.bound)
          ~bind_membership:false ~collect_outputs:true
          choice.prefix
      in
      if premises.otherwise then
        raise (Unsupported "membership choice cannot follow ElsePr");
      if Prem.known premises.bound choice.element then
        raise (Unsupported "membership choice element is already bound");
      if not (Prem.known premises.bound choice.collection) then
        raise (Unsupported "membership choice collection is unbound");
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
      equation head.term right conditions
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
        raise (Unsupported
          "maude_rule calls are only supported as premise equalities");
      let head = prepared.head in
      let premises =
        Prem.translate_all index
          ~bound:(Il.Free.Set.elements head.bound)
          ~bind_membership:false ~collect_outputs:true prems
      in
      if premises.otherwise then
        raise (Unsupported "ElsePr is not supported in a maude_rule DecD");
      let conditions =
        List.map (fun condition -> EqCondition condition) head.conditions
        @ premises.conditions
        @ List.map
            (fun condition -> EqCondition condition)
            (Param.translate_eq_conditions
               ~proven:(proven_variables prepared premises) index quants)
      in
      let right = translate_result prepared rhs in
      rule head.term right conditions


(* Equation clauses in source order, each with the complements of the earlier
   clauses that can match its input. An otherwise clause is [owise]. *)
let ordered_clauses index id clauses =
  let arguments = function App (_, args) -> args | _ -> [] in
  let source_arguments prepared =
    match prepared.clause.it with DefD (_, args, _, _) -> args
  in
  (* As for ElsePr predecessors (Reld): the source patterns and the
     translated heads may both overlap. *)
  let overlap (prepared, (head, _, _, _)) (earlier, (earlier_head, _, _, _), _) =
    List.for_all2
      (fun arg earlier_arg ->
        match arg.it, earlier_arg.it with
        | ExpA exp, ExpA earlier_exp -> Reld.source_overlap index exp earlier_exp
        | _ -> true)
      (source_arguments prepared) (source_arguments earlier)
    && Reld.inputs_may_overlap index (arguments head) (arguments earlier_head)
  in
  let added_premises prepared =
    match prepared.clause.it with
    | DefD (_, _, _, prems) -> List.filter (Prescan.is_case_premise index) prems
  in
  let for_result = Prescan.is_result_case_premise index in
  (* A clause is selected once its premises hold (Il MATCH); a failing case
     premise for its result (Def.case_premise_script) then leaves the call
     stuck. So a later clause complements the clause without them. *)
  let selection_parts prepared current =
    match prepared.clause.it with
    | DefD (quants, args, rhs, prems) when List.exists for_result prems ->
        let prems = List.filter (fun prem -> not (for_result prem)) prems in
        (* Drop the quantifiers that occurred only in the dropped premises. *)
        let free = Il.Free.(free_args args ++ free_exp rhs ++ free_prems prems) in
        let quants = Prem.used_quants free quants in
        equation_clause
          {prepared with clause = {prepared.clause with it = DefD (quants, args, rhs, prems)}}
    | DefD _ -> current
  in
  (* A failing case premise inside a premise leaves the call stuck too, but
     the complement of that premise would then hold. *)
  let complement_of prepared current (earlier, _, selection) =
    if not (List.for_all for_result (added_premises earlier)) then
      raise (Unsupported "an earlier clause has a case premise inside a premise");
    complement prepared.clause.at current selection
  in
  let step (earlier, statements) prepared =
    let (head, right, conditions, attrs) as current =
      located id prepared.clause (fun () -> equation_clause prepared)
    in
    let overlapping =
      List.filter (fun earlier -> overlap (prepared, current) earlier) earlier
    in
    (* [owise] would also apply when an earlier clause's case premise fails,
       so an otherwise clause after such a clause states its complements. *)
    let no_case_premises =
      List.for_all (fun (earlier, _, _) -> added_premises earlier = []) overlapping
    in
    let attrs =
      if no_case_premises then attrs else List.filter (fun attr -> attr <> Owise) attrs
    in
    (* The last clause applies exactly when no earlier clause does, which is
       [owise] when the earlier clauses add no case premises; it is used
       when a complement cannot be stated (for example an earlier head with
       non-ground extra structure: $f(C x) = .. before $f(y) = ..). *)
    let can_owise =
      List.length earlier = List.length clauses - 1 && no_case_premises
    in
    let attrs, complements =
      if List.mem Owise attrs then attrs, []
      else
        match
          located id prepared.clause (fun () ->
            List.map (complement_of prepared current) overlapping)
        with
        | complements -> attrs, complements
        | exception (Util.Error.Error _) when can_owise -> attrs @ [Owise], []
    in
    let conditions =
      if complements = [] then conditions
      else schedule_equation_conditions head (conditions @ complements)
    in
    let selection =
      located id prepared.clause (fun () -> selection_parts prepared current)
    in
    ( earlier @ [prepared, current, selection]
    , statements @ [equation ~attrs head right conditions] )
  in
  snd (List.fold_left step ([], []) clauses)

(* Complete DecD *)
let translate index id params result_typ clauses =
  let builtin = has_hint index id "builtin" in
  let choice = Prescan.has_membership_choice index id in
  let rule = has_hint index id "maude_rule" in
  if not builtin && choice && rule then
    raise (Unsupported "membership choice conflicts with hint(maude_rule)");
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
      header @ List.concat_map (fun prepared ->
        located id prepared.clause (fun () -> translate_clause index id prepared)) clauses
    else if rule then
      header @ List.map (fun prepared ->
        located id prepared.clause (fun () -> translate_rule_clause prepared)) clauses
    else
      header @ ordered_clauses index id clauses


(* Def-parameter specialization: a copy of a DecD whose DefP parameters are
 * fixed to declared definitions, following the source meaning
 * $g_t(xs) = $g(xs) with f := t. *)

type specialization =
  { callee : id
  ; targets : id list  (* one per DefP parameter, in parameter order *)
  ; copy : id
  }

(* Every expression of a definition, rewritten innermost first by f.
 * Specialization rewrites calls wherever they occur: in clauses, rules,
 * premises, and the arguments of types. Type notes and the two types of a
 * SubE hold no call that specialization rewrites. *)
let rec map_exp f exp =
  let e = map_exp f in
  let it =
    match exp.it with
    | VarE _ | BoolE _ | NumE _ | TextE _ -> exp.it
    | UnE (op, ot, e1) -> UnE (op, ot, e e1)
    | BinE (op, ot, e1, e2) -> BinE (op, ot, e e1, e e2)
    | CmpE (op, ot, e1, e2) -> CmpE (op, ot, e e1, e e2)
    | TupE es -> TupE (List.map e es)
    | ProjE (e1, i) -> ProjE (e e1, i)
    | CaseE (op, e1, check) -> CaseE (op, e e1, check)
    | UncaseE (e1, op) -> UncaseE (e e1, op)
    | OptE eo -> OptE (Option.map e eo)
    | TheE e1 -> TheE (e e1)
    | StrE (fields, check) ->
        StrE (List.map (fun (atom, e1) -> atom, e e1) fields, check)
    | DotE (e1, atom) -> DotE (e e1, atom)
    | CompE (e1, e2) -> CompE (e e1, e e2)
    | ListE es -> ListE (List.map e es)
    | LiftE e1 -> LiftE (e e1)
    | MemE (e1, e2) -> MemE (e e1, e e2)
    | LenE e1 -> LenE (e e1)
    | CatE (e1, e2) -> CatE (e e1, e e2)
    | IdxE (e1, e2) -> IdxE (e e1, e e2)
    | SliceE (e1, e2, e3) -> SliceE (e e1, e e2, e e3)
    | UpdE (e1, path, e2) -> UpdE (e e1, map_path f path, e e2)
    | ExtE (e1, path, e2) -> ExtE (e e1, map_path f path, e e2)
    | CallE (id, args) -> CallE (id, List.map (map_arg f) args)
    | IterE (e1, iterexp) -> IterE (e e1, map_iterexp f iterexp)
    | CvtE (e1, nt1, nt2) -> CvtE (e e1, nt1, nt2)
    | SubE (e1, t1, t2) -> SubE (e e1, t1, t2)
  in
  f {exp with it}

and map_path f path =
  let it =
    match path.it with
    | RootP -> RootP
    | IdxP (p, e) -> IdxP (map_path f p, map_exp f e)
    | SliceP (p, e1, e2) -> SliceP (map_path f p, map_exp f e1, map_exp f e2)
    | DotP (p, atom) -> DotP (map_path f p, atom)
  in
  {path with it}

and map_iter f iter =
  match iter with
  | ListN (e, x) -> ListN (map_exp f e, x)
  | Opt | List | List1 -> iter

and map_iterexp f (iter, sources) =
  map_iter f iter, List.map (fun (x, e) -> x, map_exp f e) sources

and map_arg f arg =
  let it =
    match arg.it with
    | ExpA e -> ExpA (map_exp f e)
    | TypA typ -> TypA (map_typ f typ)
    | DefA _ -> arg.it
    | GramA sym -> GramA (map_sym f sym)
  in
  {arg with it}

and map_typ f typ =
  let it =
    match typ.it with
    | VarT (id, args) -> VarT (id, List.map (map_arg f) args)
    | BoolT | NumT _ | TextT -> typ.it
    | TupT xts -> TupT (List.map (fun (x, t) -> x, map_typ f t) xts)
    | IterT (t, iter) -> IterT (map_typ f t, map_iter f iter)
  in
  {typ with it}

and map_sym f sym =
  let it =
    match sym.it with
    | VarG (id, args) -> VarG (id, List.map (map_arg f) args)
    | NumG _ | TextG _ | EpsG -> sym.it
    | SeqG syms -> SeqG (List.map (map_sym f) syms)
    | AltG syms -> AltG (List.map (map_sym f) syms)
    | RangeG (s1, s2) -> RangeG (map_sym f s1, map_sym f s2)
    | IterG (s, iterexp) -> IterG (map_sym f s, map_iterexp f iterexp)
    | AttrG (e, s) -> AttrG (map_exp f e, map_sym f s)
  in
  {sym with it}

and map_prem f prem =
  let it =
    match prem.it with
    | RulePr (id, args, op, e) -> RulePr (id, List.map (map_arg f) args, op, map_exp f e)
    | IfPr e -> IfPr (map_exp f e)
    | LetPr (quants, e1, e2) ->
        LetPr (List.map (map_param f) quants, map_exp f e1, map_exp f e2)
    | ElsePr -> ElsePr
    | IterPr (p, iterexp) -> IterPr (map_prem f p, map_iterexp f iterexp)
  in
  {prem with it}

and map_param f param =
  let it =
    match param.it with
    | ExpP (id, typ) -> ExpP (id, map_typ f typ)
    | TypP _ -> param.it
    | DefP (id, params, typ) -> DefP (id, List.map (map_param f) params, map_typ f typ)
    | GramP (id, params, typ) -> GramP (id, List.map (map_param f) params, map_typ f typ)
  in
  {param with it}

let map_case f (typ, quants, prems) =
  map_typ f typ, List.map (map_param f) quants, List.map (map_prem f) prems

let map_deftyp f deftyp =
  let it =
    match deftyp.it with
    | AliasT typ -> AliasT (map_typ f typ)
    | StructT fields ->
        StructT (List.map (fun (atom, case, hints) -> atom, map_case f case, hints) fields)
    | VariantT cases ->
        VariantT (List.map (fun (op, case, hints) -> op, map_case f case, hints) cases)
  in
  {deftyp with it}

let map_clause f clause =
  let DefD (quants, args, exp, prems) = clause.it in
  { clause with
    it =
      DefD
        ( List.map (map_param f) quants
        , List.map (map_arg f) args
        , map_exp f exp
        , List.map (map_prem f) prems ) }

let rec map_def f def =
  let params = List.map (map_param f) in
  let it =
    match def.it with
    | TypD (id, ps, insts) ->
        let inst {it = InstD (quants, args, deftyp); at; note} =
          { it = InstD (params quants, List.map (map_arg f) args, map_deftyp f deftyp)
          ; at; note }
        in
        TypD (id, params ps, List.map inst insts)
    | RelD (id, ps, op, typ, rules) ->
        let rule {it = RuleD (rid, quants, op, exp, prems); at; note} =
          { it =
              RuleD (rid, params quants, op, map_exp f exp, List.map (map_prem f) prems)
          ; at; note }
        in
        RelD (id, params ps, op, map_typ f typ, List.map rule rules)
    | DecD (id, ps, typ, clauses) ->
        DecD (id, params ps, map_typ f typ, List.map (map_clause f) clauses)
    | GramD (id, ps, typ, prods) ->
        let prod {it = ProdD (quants, sym, exp, prems); at; note} =
          { it =
              ProdD (params quants, map_sym f sym, map_exp f exp, List.map (map_prem f) prems)
          ; at; note }
        in
        GramD (id, params ps, map_typ f typ, List.map prod prods)
    | RecD defs -> RecD (List.map (map_def f) defs)
    | HintD _ -> def.it
  in
  {def with it}

(* A def parameter occurs in a clause only as a callee: passing it on as a
 * DefA is rejected when calls are collected. Def ids have no binders inside
 * clauses, so the renaming is capture-free. *)
let renaming ids targets exp =
  match exp.it with
  | CallE (callee, args) ->
      begin match List.assoc_opt callee.it (List.combine ids targets) with
      | Some target -> {exp with it = CallE (target, args)}
      | None -> exp
      end
  | _ -> exp

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
  map_clause (renaming ids targets) (DefD (quants, args, exp, prems) $ clause.at)

let specialize specialization id params result_typ clauses =
  let kept, def_params = Param.split_def_positions params params in
  let rename = renaming (Param.def_ids def_params) specialization.targets in
  DecD
    ( specialization.copy
    , List.map (map_param rename) kept
    , map_typ rename result_typ
    , List.map (specialize_clause id params specialization.targets) clauses )
