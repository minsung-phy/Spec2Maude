open Util.Source
open Il.Ast
open Maude_il

type result =
  { conditions : rule_condition list
  ; bound : Il.Free.Set.t
  ; otherwise : bool
  }

type relation_kind = Predicate | Deterministic | Execution

let variables exp = Il.Free.(free_exp exp).varid
let known bound exp = Il.Free.Set.subset (variables exp) bound
let bind bound exp = Il.Free.Set.union bound (variables exp)
let known_args bound args = Il.Free.Set.subset Il.Free.(free_args args).varid bound

let bind_names bound names =
  List.fold_left (fun bound name -> Il.Free.Set.add name bound) bound names

let make bound conditions = {conditions; bound; otherwise = false}

let rec is_pattern exp =
  match exp.it with
  | VarE _ | BoolE _ | NumE _ | TextE _ | OptE None -> true
  | TupE exps | ListE exps -> List.for_all is_pattern exps
  | CaseE (_, exp) | OptE (Some exp) -> is_pattern exp
  | StrE fields -> List.for_all (fun (_, exp) -> is_pattern exp) fields
  | _ -> false

let has_atom atoms mixop =
  Xl.Mixop.flatten mixop
  |> List.exists (List.exists (fun atom -> List.mem atom.it atoms))

let relation_kind mixop =
  if has_atom
       Xl.Atom.[SqArrow; SqArrowSub; SqArrowStar; SqArrowStarSub] mixop
  then Execution
  else if has_atom Xl.Atom.[Approx; ApproxSub] mixop
  then Deterministic
  else if has_atom Xl.Atom.[Turnstile; TurnstileSub; Sub] mixop
  then Predicate
  else invalid_arg "unsupported RulePr relation marker"

let components mixop exp =
  match Xl.Mixop.arity mixop, exp.it with
  | 0, TupE [] -> []
  | 1, _ -> [exp]
  | arity, TupE exps when List.length exps = arity -> exps
  | _ -> invalid_arg "RulePr expression does not match its mixop"

let split count items =
  let rec aux count left = function
    | right when count = 0 -> List.rev left, right
    | item :: items -> aux (count - 1) (item :: left) items
    | [] -> invalid_arg "malformed execution RulePr"
  in
  aux count [] items

let split_execution mixop exps =
  let markers =
    Xl.Atom.[SqArrow; SqArrowSub; SqArrowStar; SqArrowStarSub]
  in
  let positions =
    Xl.Mixop.flatten mixop
    |> List.mapi (fun index atoms ->
         atoms
         |> List.filter_map (fun atom ->
              if List.mem atom.it markers then Some index else None))
    |> List.concat
  in
  match positions with
  | [count] when count > 0 && count < List.length exps ->
      split count exps
  | [] ->
      invalid_arg "execution RulePr has no execution marker"
  | [_] ->
      invalid_arg "execution RulePr marker requires input and output components"
  | _ ->
      invalid_arg "execution RulePr has multiple execution markers"

let relation_call id args exps =
  App
    ( Term.source_name id
    , List.map Term.translate_arg args @ List.map Term.translate_exp exps
    )

let tuple = function
  | [] -> Const "eps"
  | [exp] -> Term.translate_exp exp
  | exps ->
      exps
      |> List.map (fun exp ->
           Term.translate_exp exp |> Term.as_sequence_element exp.note)
      |> Term.sequence
      |> fun terms -> App ("tuple", [terms])

let translate_rulepr bound id args mixop exp =
  let exps = components mixop exp in
  match relation_kind mixop with
  | Predicate ->
      if not (known_args bound args && known bound exp) then
        invalid_arg "predicate RulePr contains an unbound variable";
      make bound [EqCondition (BoolCond (relation_call id args exps))]
  | Deterministic ->
      begin match List.rev exps with
      | output :: inputs_rev ->
          let inputs = List.rev inputs_rev in
          let call = relation_call id args inputs in
          let output_term = Term.translate_exp output in
          if not (known_args bound args && List.for_all (known bound) inputs) then
            invalid_arg "deterministic RulePr has an unbound input";
          if known bound output then
            make bound [EqCondition (EqCond (output_term, call))]
          else if is_pattern output then
            make (bind bound output)
              [EqCondition (MatchCond (output_term, call))]
          else
            invalid_arg "deterministic RulePr output is not a pattern"
      | [] -> invalid_arg "deterministic RulePr has no output"
      end
  | Execution ->
      let inputs, outputs = split_execution mixop exps in
      if not (known_args bound args && List.for_all (known bound) inputs) then
        invalid_arg "execution RulePr has an unbound input";
      if not (List.for_all is_pattern outputs) then
        invalid_arg "execution RulePr output is not a pattern";
      make (List.fold_left bind bound outputs)
        [RewriteCond (relation_call id args inputs, tuple outputs)]

let translate_ifpr bound exp =
  if not (known bound exp) then
    invalid_arg "IfPr contains an unbound variable";
  make bound [EqCondition (BoolCond (Term.translate_bool exp))]

let translate_letpr bound quants left right =
  if not (known bound right) then invalid_arg "LetPr right side is unbound";
  if not (is_pattern left) then invalid_arg "LetPr left side is not a pattern";
  let names =
    List.filter_map
      (fun quant ->
        match quant.it with ExpP (id, _) -> Some id.it | _ -> None)
      quants
  in
  let conditions =
    EqCondition (MatchCond (Term.translate_exp left, Term.translate_exp right))
    :: List.map (fun condition -> EqCondition condition)
         (Param.translate_eq_conditions quants)
  in
  make (bind (bind_names bound names) left) conditions

let translate index bound prem =
  match prem.it with
  | RulePr (id, args, mixop, exp) ->
      translate_rulepr bound id args mixop exp
  | IfPr exp ->
      translate_ifpr bound exp
  | LetPr (quants, left, right) ->
      translate_letpr bound quants left right
  | ElsePr ->
      {conditions = []; bound; otherwise = true}
  | IterPr (_, (iter, generators)) ->
      if not (List.for_all (fun (_, source) -> known bound source) generators) then
        invalid_arg "IterPr has an unbound generator source";
      begin match iter with
      | ListN (count, _) when not (known bound count) ->
          invalid_arg "IterPr has an unbound iteration count"
      | Opt | List | List1 | ListN _ -> ()
      end;
      make bound
        (Iter.translate_premise index Term.translate_exp Term.translate_sort prem)
  | NegPr _ ->
      invalid_arg "NegPr requires a total source-derived complement"

let rec translate_prems index result = function
  | [] -> result
  | prem :: prems ->
      let next = translate index result.bound prem in
      translate_prems index
        { conditions = result.conditions @ next.conditions
        ; bound = next.bound
        ; otherwise = result.otherwise || next.otherwise
        }
        prems

let translate_all index ?(bound = []) prems =
  let bound = bind_names Il.Free.Set.empty bound in
  translate_prems index {conditions = []; bound; otherwise = false} prems

let translate_eq_conditions index ?bound prems =
  let result = translate_all index ?bound prems in
  if result.otherwise then invalid_arg "ElsePr belongs to DecD or RelD";
  List.map
    (function
      | EqCondition condition -> condition
      | RewriteCond _ -> invalid_arg "an equation cannot use a rewrite condition")
    result.conditions
