open Util.Source
open Il.Ast
open Maude_il

type result =
  { conditions : rule_condition list
  ; bound : Il.Free.Set.t
  ; otherwise : bool
  }

type relation_shape =
  | Predicate of exp list
  | Deterministic of exp list * exp list
  | Execution of exp list * exp list

let variables exp = Il.Free.(free_exp exp).varid
let known bound exp = Il.Free.Set.subset (variables exp) bound
let bind bound exp = Il.Free.Set.union bound (variables exp)
let known_args bound args = Il.Free.Set.subset Il.Free.(free_args args).varid bound

let bind_names bound names =
  List.fold_left (fun bound name -> Il.Free.Set.add name bound) bound names

let make bound conditions = {conditions; bound; otherwise = false}

type pattern =
  { term : term
  ; guards : eq_condition list
  }

let pattern term = {term; guards = []}

let pattern_terms patterns =
  List.map (fun pattern -> pattern.term) patterns

let pattern_guards patterns =
  List.concat_map (fun pattern -> pattern.guards) patterns

let rec translate_pattern index exp =
  match exp.it with
  | VarE _ | BoolE _ | NumE _ | TextE _ | OptE None ->
      Some (pattern (Term.translate_exp index exp))

  | TupE exps ->
      translate_sequence_pattern index "tuple" exps

  | ListE exps ->
      translate_list_pattern index exps

  | CaseE (mixop, payload) ->
      translate_case_pattern index mixop payload

  | OptE (Some inner) ->
      translate_pattern index inner
      |> Option.map (fun pattern ->
           { pattern with
             term =
               App
                 ("_?", [Term.as_sequence_element inner.note pattern.term])
           })

  | StrE fields ->
      translate_field_patterns index fields
      |> Option.map (fun (items, guards) ->
           {term = App ("{_}", [Term.record_items items]); guards})

  | SubE (inner, source, _) ->
      translate_pattern index inner
      |> Option.map (fun pattern ->
           { pattern with
             guards =
               pattern.guards
               @ Term.translate_typ_conditions index pattern.term source
           })

  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _ | DotE _
  | CompE _ | LiftE _ | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _
  | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _ | CvtE _ ->
      None

and translate_patterns index = function
  | [] -> Some []
  | exp :: exps ->
      begin match translate_pattern index exp, translate_patterns index exps with
      | Some pattern, Some patterns -> Some (pattern :: patterns)
      | None, _ | _, None -> None
      end

and translate_sequence_pattern index name exps =
  translate_patterns index exps
  |> Option.map (fun patterns ->
       let terms =
         List.map2
           (fun exp pattern ->
             Term.as_sequence_element exp.note pattern.term)
           exps patterns
       in
       { term = App (name, [Term.sequence terms])
       ; guards = pattern_guards patterns
       })

and translate_list_pattern index exps =
  translate_patterns index exps
  |> Option.map (fun patterns ->
       let terms =
         List.map2
           (fun exp pattern ->
             Term.as_sequence_element exp.note pattern.term)
           exps patterns
       in
       {term = Term.sequence terms; guards = pattern_guards patterns})

and translate_case_pattern index mixop payload =
  if Mixop.is_hole_only mixop then
    match payload.it with
    | TupE [single] -> translate_pattern index single
    | _ -> translate_pattern index payload
  else
    match payload.it with
    | TupE exps ->
        translate_patterns index exps
        |> Option.map (fun patterns ->
             { term =
                 App (Prescan.mixop_name index mixop, pattern_terms patterns)
             ; guards = pattern_guards patterns
             })
    | _ ->
        translate_pattern index payload
        |> Option.map (fun pattern ->
             { pattern with
               term = App (Prescan.mixop_name index mixop, [pattern.term])
             })

and translate_field_patterns index = function
  | [] -> Some ([], [])
  | (atom, exp) :: fields ->
      begin match
        translate_pattern index exp,
        translate_field_patterns index fields
      with
      | Some pattern, Some (items, guards) ->
          Some
            ( App ("item", [Term.qid_of_atom atom; pattern.term]) :: items
            , pattern.guards @ guards
            )
      | None, _ | _, None -> None
      end

let rule_guards pattern =
  List.map (fun guard -> EqCondition guard) pattern.guards

let rec bind_pattern index bound exp subject error =
  match exp.it with
  | ProjE ({it = UncaseE (inner, mixop); _}, 0)
    when Xl.Mixop.arity mixop = 1 ->
      let represented =
        if Mixop.is_hole_only mixop then subject
        else App (Prescan.mixop_name index mixop, [subject])
      in
      bind_pattern index bound inner represented error
  | _ ->
      begin match translate_pattern index exp with
      | Some pattern ->
          make (bind bound exp)
            (EqCondition (MatchCond (pattern.term, subject))
             :: rule_guards pattern)
      | None -> invalid_arg error
      end

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

let marker_position markers mixop =
  let positions =
    Xl.Mixop.flatten mixop
    |> List.mapi (fun index atoms ->
         atoms
         |> List.filter_map (fun atom ->
              if List.mem atom.it markers then
                Some (index + if Xl.Atom.is_sub atom then 1 else 0)
              else None))
    |> List.concat
  in
  match positions with
  | [] -> None
  | [position] -> Some position
  | _ -> invalid_arg "RulePr relation has multiple direction markers"

let relation_shape mixop exps =
  let execution =
    Xl.Atom.[SqArrow; SqArrowSub; SqArrowStar; SqArrowStarSub]
  in
  match marker_position execution mixop with
  | Some position when position > 0 && position < List.length exps ->
      let inputs, outputs = split position exps in
      Execution (inputs, outputs)
  | Some _ ->
      invalid_arg "execution RulePr marker requires input and output components"
  | None ->
      begin match marker_position Xl.Atom.[Approx; ApproxSub] mixop with
      | Some position when position < List.length exps ->
          let inputs, outputs = split position exps in
          Deterministic (inputs, outputs)
      | Some _ ->
          invalid_arg "deterministic RulePr marker requires an output component"
      | None ->
          begin match marker_position Xl.Atom.[Colon; ColonSub] mixop with
          | Some position when position < List.length exps ->
              let inputs, outputs = split position exps in
              Deterministic (inputs, outputs)
          | Some _ | None -> Predicate exps
          end
      end

let relation_call index id args exps =
  App
    ( Prescan.rel_name index id
    , List.map (Term.translate_arg index) args
      @ List.map (Term.translate_exp index) exps
    )

let tuple exps terms =
  match exps, terms with
  | [], [] -> Const "eps"
  | [_], [term] -> term
  | _, _ ->
      List.map2
        (fun exp term -> Term.as_sequence_element exp.note term)
        exps terms
      |> Term.sequence
      |> fun terms -> App ("tuple", [terms])

let translate_rulepr index bound id args mixop exp =
  let exps = components mixop exp in
  match relation_shape mixop exps with
  | Predicate inputs ->
      if not (known_args bound args && known bound exp) then
        invalid_arg "predicate RulePr contains an unbound variable";
      make bound [EqCondition (BoolCond (relation_call index id args inputs))]
  | Deterministic (inputs, outputs) ->
      if not (known_args bound args && List.for_all (known bound) inputs) then
        invalid_arg "deterministic RulePr has an unbound input";
      let call = relation_call index id args inputs in
      if List.for_all (known bound) outputs then
        make bound
          [EqCondition
             (EqCond
                ( tuple outputs (List.map (Term.translate_exp index) outputs)
                , call
                ))]
      else
        begin match translate_patterns index outputs with
        | Some patterns ->
            make (List.fold_left bind bound outputs)
              (EqCondition
                 (MatchCond (tuple outputs (pattern_terms patterns), call))
               :: List.concat_map rule_guards patterns)
        | None ->
            invalid_arg "deterministic RulePr output is not a pattern"
        end
  | Execution (inputs, outputs) ->
      if not (known_args bound args && List.for_all (known bound) inputs) then
        invalid_arg "execution RulePr has an unbound input";
      begin match translate_patterns index outputs with
      | Some patterns ->
          make (List.fold_left bind bound outputs)
            (RewriteCond
               ( relation_call index id args inputs
               , tuple outputs (pattern_terms patterns)
               )
             :: List.concat_map rule_guards patterns)
      | None ->
          invalid_arg "execution RulePr output is not a pattern"
      end

let translate_inverse index bound equality id args result =
  match Prescan.inverse index id with
  | None -> invalid_arg "IfPr requires a declared inverse"
  | Some inverse ->
      let known_arg arg =
        Il.Free.Set.subset Il.Free.(free_arg arg).varid bound
      in
      let selected, remaining =
        args
        |> List.mapi (fun position arg -> position, arg)
        |> List.partition (fun (position, _) -> position = inverse.missing)
      in
      begin match selected with
      | [_, ({it = ExpA pattern; _} as missing)]
        when not (known_arg missing)
          && List.for_all (fun (_, arg) -> known_arg arg) remaining ->
          let inverse_call =
            App
              ( Prescan.def_name index inverse.inverse_target
              , List.map
                  (fun (_, arg) -> Term.translate_arg index arg)
                  remaining
                @ [Term.translate_exp index result]
              )
          in
          let binding =
            bind_pattern index bound pattern inverse_call
              "inverse result is not a pattern"
          in
          make binding.bound
            (binding.conditions
             @ [EqCondition (BoolCond (Term.translate_bool index equality))])
      | _ ->
          invalid_arg
            "inverse requires exactly its declared argument to be unbound"
      end

let rec translate_ifpr index bound exp =
  match exp.it with
  | BinE (`AndOp, `BoolT, left, right) when not (known bound exp) ->
      let left = translate_ifpr index bound left in
      let right = translate_ifpr index left.bound right in
      make right.bound (left.conditions @ right.conditions)

  | CmpE (`EqOp, _, ({it = CallE (id, args); _} as call), result)
    when not (known bound call) && known bound result ->
      translate_inverse index bound exp id args result

  | CmpE (`EqOp, _, result, ({it = CallE (id, args); _} as call))
    when known bound result && not (known bound call) ->
      translate_inverse index bound exp id args result

  | CmpE (`EqOp, _, pattern, subject)
    when not (known bound pattern) && known bound subject ->
      bind_pattern index bound pattern (Term.translate_exp index subject)
        "IfPr left side is not a pattern"

  | CmpE (`EqOp, _, subject, pattern)
    when known bound subject && not (known bound pattern) ->
      bind_pattern index bound pattern (Term.translate_exp index subject)
        "IfPr right side is not a pattern"

  | _ ->
      if not (known bound exp) then
        invalid_arg "IfPr contains an unbound variable";
      make bound [EqCondition (BoolCond (Term.translate_bool index exp))]

let translate_letpr index bound quants left right =
  if not (known bound right) then invalid_arg "LetPr right side is unbound";
  let result =
    bind_pattern index bound left (Term.translate_exp index right)
      "LetPr left side is not a pattern"
  in
  let names =
    List.filter_map
      (fun quant ->
        match quant.it with ExpP (id, _) -> Some id.it | _ -> None)
      quants
  in
  let conditions =
    result.conditions
    @ List.map (fun condition -> EqCondition condition)
         (Param.translate_eq_conditions index quants)
  in
  make (bind_names result.bound names) conditions

let translate index bound prem =
  match prem.it with
  | RulePr (id, args, mixop, exp) ->
      translate_rulepr index bound id args mixop exp
  | IfPr exp ->
      translate_ifpr index bound exp
  | LetPr (quants, left, right) ->
      translate_letpr index bound quants left right
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
        (Iter.translate_premise index (Term.translate_exp index) prem)
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
