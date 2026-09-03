open Util.Source
open Il.Ast
open Maude_il

type result =
  { conditions : rule_condition list
  ; bound : Il.Free.Set.t
  ; otherwise : bool
  }

let variables exp = Il.Free.(free_exp exp).varid
let known bound exp = Il.Free.Set.subset (variables exp) bound
let bind bound exp = Il.Free.Set.union bound (variables exp)
let known_args bound args = Il.Free.Set.subset Il.Free.(free_args args).varid bound

let bind_names bound names =
  List.fold_left (fun bound name -> Il.Free.Set.add name bound) bound names

let make bound conditions = {conditions; bound; otherwise = false}

let is_rewrite_call index exp =
  match exp.it with
  | CallE (id, _) ->
      Prescan.definition_call index exp = None
      && Prescan.definition_requires_rewrite index id
  | _ -> false

let has_rewrite_call index exp =
  let found = ref false in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      if is_rewrite_call index exp then found := true
  end)
  in
  Visitor.exp exp;
  !found

let arg_has_rewrite_call index arg =
  match arg.it with
  | ExpA exp -> has_rewrite_call index exp
  | TypA _ | DefA _ | GramA _ -> false

let prem_has_rewrite_call index prem =
  let found = ref false in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      if is_rewrite_call index exp then found := true
  end)
  in
  Visitor.prem prem;
  !found

type attempt =
  | Ready of result
  | Waiting

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
      translate_list_pattern index exp.note exps

  | CatE (left, right) ->
      begin match translate_pattern index left, translate_pattern index right with
      | Some left, Some right ->
          Some
            { term =
                Term.concat_for_sort
                  (Prescan.sort_of_typ index exp.note) left.term right.term
            ; guards = left.guards @ right.guards
            }
      | None, _ | _, None -> None
      end

  | CaseE (mixop, payload) ->
      translate_case_pattern index mixop payload

  | OptE (Some inner) ->
      translate_pattern index inner
      |> Option.map (fun pattern ->
           { pattern with
             term =
               App
                 ("_?", [Term.as_sequence_element index inner.note pattern.term])
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

  | IterE (body, iterexp) ->
      Iter.translate_identity_pattern
        index
        (fun exp ->
          translate_pattern index exp
          |> Option.map (fun pattern -> pattern.term, pattern.guards))
        (Term.translate_typ_conditions index)
        body iterexp
      |> Option.map (fun (term, guards) -> {term; guards})

  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | TheE _ | DotE _
  | CompE _ | LiftE _ | MemE _ | LenE _ | IdxE _ | SliceE _
  | UpdE _ | ExtE _ | IfE _ | CallE _ | CvtE _ ->
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
             Term.as_sequence_element index exp.note pattern.term)
           exps patterns
       in
       { term = App (name, [Term.sequence terms])
       ; guards = pattern_guards patterns
       })

and translate_list_pattern index list_typ exps =
  translate_patterns index exps
  |> Option.map (fun patterns ->
       let terms =
         List.map2
           (fun exp pattern ->
             Term.as_sequence_element index exp.note pattern.term)
           exps patterns
       in
       { term =
           Term.sequence_for_sort
             (Prescan.sort_of_typ index list_typ) terms
       ; guards = pattern_guards patterns
       })

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

let translate_pattern_parts index exp =
  translate_pattern index exp
  |> Option.map (fun pattern -> pattern.term, pattern.guards)

let rule_guards pattern =
  List.map (fun guard -> EqCondition guard) pattern.guards

type inverse_plan =
  { missing_pattern : exp
  ; inverse_target : id
  ; remaining_args : arg list
  }

let inverse_plan index bound id args =
  match Prescan.inverse index id with
  | None -> None
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
      | [_, {it = ExpA pattern; _}] ->
          if not (known bound pattern)
             && List.for_all (fun (_, arg) -> known_arg arg) remaining
          then
            Some
              { missing_pattern = pattern
              ; inverse_target = inverse.inverse_target
              ; remaining_args = List.map snd remaining
              }
          else None
      | [_] ->
          invalid_arg "inverse missing argument is not an expression"
      | _ ->
          invalid_arg "inverse argument position does not match the call"
      end

let inverse_call index plan subject =
  App
    ( Prescan.def_name index plan.inverse_target
    , List.map (Term.translate_arg index) plan.remaining_args @ [subject]
    )

let can_bind_computed_pattern index bound exp =
  match exp.it with
  | CallE (id, args) -> Option.is_some (inverse_plan index bound id args)
  | _ -> false

let direct_numeric_variable index bound exp =
  match exp.it, Prescan.sort_of_typ index exp.note with
  | VarE _, ("Nat" | "Int") -> not (known bound exp)
  | _ -> false

let rec bind_pattern index bound exp subject error =
  match exp.it with
  | _ when known bound exp ->
      make bound
        [EqCondition (EqCond (Term.translate_exp index exp, subject))]
  | CvtE (inner, source, target) ->
      begin match target, source with
      | (`NatT | `IntT | `RatT), (`NatT | `IntT | `RatT)
      | `RealT, `RealT ->
          let converted =
            App
              ( "_:_<:>_"
              , [ subject
                ; Const (Xl.Num.string_of_typ target)
                ; Const (Xl.Num.string_of_typ source)
                ]
              )
          in
          bind_pattern index bound inner converted error
      | _ ->
          invalid_arg
            "CvtE pattern requires an exact backend numeric conversion"
      end
  | ProjE ({it = UncaseE (inner, mixop); _}, 0)
    when Xl.Mixop.arity mixop = 1 ->
      let represented =
        if Mixop.is_hole_only mixop then subject
        else App (Prescan.mixop_name index mixop, [subject])
      in
      bind_pattern index bound inner represented error
  | BinE (`MulOp, (`NatT | `IntT), left, right) ->
      let target, factor =
        if direct_numeric_variable index bound left && known bound right then
          left, right
        else if
          known bound left && direct_numeric_variable index bound right
        then
          right, left
        else
          invalid_arg (error ^ ": " ^ Il.Print.string_of_exp exp)
      in
      let factor_term = Term.translate_exp index factor in
      let result =
        bind_pattern index bound target
          (App ("_quo_", [subject; factor_term])) error
      in
      { result with
        conditions =
          EqCondition
            (BoolCond (App ("_=/=_", [factor_term; Const "0"])))
          :: result.conditions
          @ [EqCondition (EqCond (Term.translate_exp index exp, subject))]
      }
  | CallE (id, args) ->
      begin match inverse_plan index bound id args with
      | Some plan ->
          let result =
            bind_pattern index bound plan.missing_pattern
              (inverse_call index plan subject) error
          in
          { result with
            conditions =
              result.conditions
              @ [EqCondition
                   (EqCond (Term.translate_exp index exp, subject))]
          }
      | None -> bind_structural_pattern index bound exp subject error
      end
  | IterE (body, iterexp) ->
      begin match
        Iter.translate_pattern index
          (translate_pattern_parts index)
          (Term.translate_exp index)
          (Term.translate_typ_conditions index)
          (known bound)
          (fun name -> Il.Free.Set.mem name bound)
          (can_bind_computed_pattern index)
          body iterexp subject
      with
      | Some conditions ->
          make (bind bound exp) (List.map (fun c -> EqCondition c) conditions)
      | None -> invalid_arg error
      end
  | _ ->
      begin match translate_pattern index exp with
      | Some pattern ->
          make (bind bound exp)
            (EqCondition (MatchCond (pattern.term, subject))
             :: rule_guards pattern)
      | None -> bind_structural_pattern index bound exp subject error
      end

and bind_structural_pattern index bound exp subject error =
  match exp.it with
  | TupE exps ->
      let subjects = pattern_subjects index "TUPLE-PART" exps in
      let represented =
        List.map2
          (fun exp subject -> Term.as_sequence_element index exp.note subject)
          exps subjects
        |> Term.sequence
        |> fun terms -> App ("tuple", [terms])
      in
      bind_pattern_parts index bound exps subjects
        [EqCondition (MatchCond (represented, subject))] error
  | ListE exps ->
      let subjects = pattern_subjects index "LIST-PART" exps in
      let represented =
        List.map2
          (fun exp subject -> Term.as_sequence_element index exp.note subject)
          exps subjects
        |> Term.sequence_for_sort (Prescan.sort_of_typ index exp.note)
      in
      bind_pattern_parts index bound exps subjects
        [EqCondition (MatchCond (represented, subject))] error
  | CatE (left, right) ->
      let exps = [left; right] in
      let subjects = pattern_subjects index "CONCAT-PART" exps in
      bind_pattern_parts index bound exps subjects
        [EqCondition
           (MatchCond
              ( Term.concat_for_sort
                  (Prescan.sort_of_typ index exp.note)
                  (List.nth subjects 0) (List.nth subjects 1)
              , subject
              ))]
        error
  | CaseE (mixop, payload) ->
      bind_case_pattern index bound mixop payload subject error
  | OptE (Some inner) ->
      let inner_subject = pattern_subject index "OPTION-PART" inner in
      let represented =
        App ("_?", [Term.as_sequence_element index inner.note inner_subject])
      in
      bind_pattern_parts index bound [inner] [inner_subject]
        [EqCondition (MatchCond (represented, subject))] error
  | StrE fields ->
      let exps = List.map snd fields in
      let subjects = pattern_subjects index "FIELD-PART" exps in
      let represented =
        List.map2
          (fun (atom, _) value ->
            App ("item", [Term.qid_of_atom atom; value]))
          fields subjects
        |> Term.record_items
        |> fun items -> App ("{_}", [items])
      in
      bind_pattern_parts index bound exps subjects
        [EqCondition (MatchCond (represented, subject))] error
  | SubE (inner, source, _) ->
      let result = bind_pattern index bound inner subject error in
      { result with
        conditions =
          result.conditions
          @ List.map (fun c -> EqCondition c)
              (Term.translate_typ_conditions index subject source)
      }
  | VarE _ | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _
  | ProjE _ | UncaseE _ | OptE None | TheE _ | DotE _ | CompE _
  | LiftE _ | MemE _ | LenE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _
  | IfE _ | CallE _ | IterE _ | CvtE _ ->
      invalid_arg (error ^ ": " ^ Il.Print.string_of_exp exp)

and pattern_subject index prefix exp =
  Var (generated_variable prefix (Term.translate_sort index exp.note))

and pattern_subjects index prefix exps =
  List.mapi
    (fun position exp ->
      pattern_subject index (prefix ^ string_of_int (position + 1)) exp)
    exps

and bind_pattern_parts index bound exps subjects conditions error =
  let parts = List.combine exps subjects in
  let direct, structural =
    List.partition
      (fun (exp, _) -> Option.is_some (translate_pattern index exp))
      parts
  in
  List.fold_left
    (fun result (exp, subject) ->
      let next = bind_pattern index result.bound exp subject error in
      { next with conditions = result.conditions @ next.conditions })
    (make bound conditions) (direct @ structural)

and bind_case_pattern index bound mixop payload subject error =
  if Mixop.is_hole_only mixop then
    match payload.it with
    | TupE [single] -> bind_pattern index bound single subject error
    | _ -> bind_pattern index bound payload subject error
  else
    let exps = match payload.it with TupE exps -> exps | _ -> [payload] in
    let subjects = pattern_subjects index "CASE-PART" exps in
    let represented = App (Prescan.mixop_name index mixop, subjects) in
    bind_pattern_parts index bound exps subjects
      [EqCondition (MatchCond (represented, subject))] error

let output_subjects index outputs =
  pattern_subjects index "REL-OUTPUT" outputs

let bind_outputs index bound outputs subjects conditions error =
  bind_pattern_parts index bound outputs subjects conditions error

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

let relation_call index id args exps =
  App
    ( Prescan.rel_name index id
    , List.map (Term.translate_arg index) args
      @ List.map (Term.translate_exp index) exps
    )

let tuple index exps terms =
  match exps, terms with
  | [], [] -> Const "eps"
  | [_], [term] -> term
  | _, _ ->
      List.map2
        (fun exp term -> Term.as_sequence_element index exp.note term)
        exps terms
      |> Term.sequence
      |> fun terms -> App ("tuple", [terms])

let translate_rulepr index bound id args mixop exp =
  let exps = components mixop exp in
  let policy =
    match Prescan.relation_policy index id with
    | Ok policy -> policy
    | Error reason ->
        invalid_arg
          ("RulePr target " ^ id.it ^ " is unsupported: " ^ reason)
  in
  match policy with
  | Prescan.Predicate | Prescan.BackendCheck ->
      if not (known_args bound args && known bound exp) then
        invalid_arg "predicate RulePr contains an unbound variable";
      make bound [EqCondition (BoolCond (relation_call index id args exps))]
  | Prescan.Equation {input_count}
  | Prescan.BackendCompute {input_count} ->
      let inputs, outputs = split input_count exps in
      if not (known_args bound args && List.for_all (known bound) inputs) then
        invalid_arg "equation RulePr has an unbound input";
      let call = relation_call index id args inputs in
      if List.for_all (known bound) outputs then
        make bound
          [EqCondition
             (EqCond
                ( tuple index outputs
                    (List.map (Term.translate_exp index) outputs)
                , call
                ))]
      else
        begin match translate_patterns index outputs with
        | Some patterns ->
            make (List.fold_left bind bound outputs)
              (EqCondition
                 (MatchCond
                    (tuple index outputs (pattern_terms patterns), call))
               :: List.concat_map rule_guards patterns)
        | None ->
            let subjects = output_subjects index outputs in
            bind_outputs index bound outputs subjects
              [EqCondition
                 (MatchCond (tuple index outputs subjects, call))]
              "equation RulePr output is not a structural pattern"
        end
  | Prescan.Execution {input_count; _} ->
      let inputs, outputs = split input_count exps in
      if not (known_args bound args && List.for_all (known bound) inputs) then
        invalid_arg "execution RulePr has an unbound input";
      begin match translate_patterns index outputs with
      | Some patterns ->
          make (List.fold_left bind bound outputs)
            (RewriteCond
               ( relation_call index id args inputs
               , tuple index outputs (pattern_terms patterns)
               )
             :: List.concat_map rule_guards patterns)
      | None ->
          let subjects = output_subjects index outputs in
          let binding =
            bind_outputs index bound outputs subjects []
              "execution RulePr output is not a structural pattern"
          in
          make binding.bound
            (RewriteCond
               (relation_call index id args inputs,
                tuple index outputs subjects)
             :: binding.conditions)
      end

let translate_inverse index bound equality id args result =
  match inverse_plan index bound id args with
  | None -> Waiting
  | Some plan ->
      let binding =
        bind_pattern index bound plan.missing_pattern
          (inverse_call index plan (Term.translate_exp index result))
          "inverse result is not a pattern"
      in
      Ready
        (make binding.bound
           (binding.conditions
            @ [EqCondition (BoolCond (Term.translate_bool index equality))]))

let translate_rewrite_call index bound call result =
  if not (known bound call) then Waiting
  else
    let call = Term.translate_exp index call in
    if known bound result then
      Ready
        (make bound
           [RewriteCond (call, Term.translate_exp index result)])
    else
      match translate_pattern index result with
      | Some pattern ->
          Ready
            (make (bind bound result)
               (RewriteCond (call, pattern.term) :: rule_guards pattern))
      | None ->
          invalid_arg "rewrite-backed call result is not a pattern"

let translate_binding_membership index bound element collection =
  match collection.note.it, translate_pattern index element with
  | IterT _, Some pattern ->
      let collection_sort =
        Term.translate_sort index collection.note |> Term.sequence_tail_sort
      in
      let prefix = Var (generated_variable "MEMBER-PREFIX" collection_sort) in
      let suffix = Var (generated_variable "MEMBER-SUFFIX" collection_sort) in
      let selected =
        Term.as_sequence_element index element.note pattern.term
      in
      let sequence =
        Term.sequence_for_sort collection_sort [prefix; selected; suffix]
      in
      Ready
        (make (bind bound element)
           (EqCondition
              (MatchCond (sequence, Term.translate_exp index collection))
            :: rule_guards pattern))
  | IterT _, None ->
      invalid_arg "binding membership element is not a pattern"
  | _ ->
      invalid_arg "binding membership requires an iterated collection"

let rec translate_ifpr index bind_membership bound exp =
  match exp.it with
  | CmpE (`EqOp, _, ({it = CallE _; _} as call), result)
    when is_rewrite_call index call ->
      translate_rewrite_call index bound call result

  | CmpE (`EqOp, _, result, ({it = CallE _; _} as call))
    when is_rewrite_call index call ->
      translate_rewrite_call index bound call result

  | _ when has_rewrite_call index exp ->
      invalid_arg
        "rewrite-backed call must be a top-level equality premise"

  | MemE (_, collection) when not (known bound collection) ->
      Waiting

  | MemE (element, collection)
    when bind_membership && not (known bound element) ->
      translate_binding_membership index bound element collection

  | MemE (element, _) when not (known bound element) ->
      invalid_arg
        "binding membership must be a final definition choice"

  | BinE (`AndOp, `BoolT, left, right) when not (known bound exp) ->
      begin match translate_ifpr index bind_membership bound left with
      | Waiting ->
          begin match translate_ifpr index bind_membership bound right with
          | Waiting -> Waiting
          | Ready right ->
              begin match
                translate_ifpr index bind_membership right.bound left
              with
              | Waiting -> Waiting
              | Ready left ->
                  Ready
                    (make left.bound (right.conditions @ left.conditions))
              end
          end
      | Ready left ->
          begin match translate_ifpr index bind_membership left.bound right with
          | Waiting -> Waiting
          | Ready right ->
              Ready
                (make right.bound (left.conditions @ right.conditions))
          end
      end

  | CmpE (`EqOp, _, ({it = CallE (id, args); _} as call), result)
    when not (known bound call) && known bound result ->
      translate_inverse index bound exp id args result

  | CmpE (`EqOp, _, result, ({it = CallE (id, args); _} as call))
    when known bound result && not (known bound call) ->
      translate_inverse index bound exp id args result

  | CmpE (`EqOp, _, pattern, subject)
    when not (known bound pattern) && known bound subject ->
      Ready
        (bind_pattern index bound pattern (Term.translate_exp index subject)
           "IfPr left side is not a pattern")

  | CmpE (`EqOp, _, subject, pattern)
    when known bound subject && not (known bound pattern) ->
      Ready
        (bind_pattern index bound pattern (Term.translate_exp index subject)
           "IfPr right side is not a pattern")

  | _ ->
      if known bound exp then
        Ready (make bound [EqCondition (BoolCond (Term.translate_bool index exp))])
      else
        Waiting

let translate_letpr index bound quants left right =
  if not (known bound right) then Waiting
  else
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
    Ready (make (bind_names result.bound names) conditions)

let translate_barrier index request_output bound prem =
  match prem.it with
  | RulePr (id, args, mixop, exp) ->
      translate_rulepr index bound id args mixop exp
  | ElsePr ->
      {conditions = []; bound; otherwise = true}
  | IterPr (_, (iter, generators)) ->
      let iteration =
        match Prescan.premise_iteration index prem with
        | Some iteration -> iteration
        | None -> invalid_arg "IterPr is missing from the prescan index"
      in
      if not
           (List.for_all
              (function
                | Prescan.VariableCapture (id, _) ->
                    Il.Free.Set.mem id.it bound
                | Prescan.DefinitionCapture _ -> true)
              iteration.Prescan.captures)
      then invalid_arg "IterPr has an unbound capture";
      begin match iter with
      | ListN (count, _) when not (known bound count) ->
          invalid_arg "IterPr has an unbound iteration count"
      | Opt | List | List1 | ListN _ -> ()
      end;
      let unknown =
        generators
        |> List.mapi (fun position (_, source) -> position, source)
        |> List.filter (fun (_, source) -> not (known bound source))
      in
      begin match unknown with
      | [] ->
          make bound
            (Iter.translate_premise index (Term.translate_exp index) prem)
      | [position, source]
        when Iter.premise_output_possible iteration position ->
          begin match request_output with
          | Some request -> request iteration position
          | None ->
              invalid_arg "IterPr output requires relation helper collection"
          end;
          bind_pattern index bound source
            (Iter.premise_output_call index (Term.translate_exp index)
               iteration position)
            "IterPr output source is not a structural pattern"
      | [_] ->
          invalid_arg "IterPr body does not determine its unbound source"
      | _ ->
          invalid_arg "IterPr has multiple unbound generator sources"
      end
  | NegPr _ ->
      invalid_arg "NegPr requires a total source-derived complement"
  | IfPr _ | LetPr _ ->
      invalid_arg "internal error: pure premise reached a barrier"

let append result next =
  { conditions = result.conditions @ next.conditions
  ; bound = next.bound
  ; otherwise = result.otherwise || next.otherwise
  }

let rec translate_prems index bind_membership request_output result skipped = function
  | [] when skipped = [] -> result
  | [] ->
      invalid_arg "pure premises have unresolved variable dependencies"
  | prem :: prems ->
      begin match prem.it with
      | IfPr exp ->
          begin match
            translate_ifpr index bind_membership result.bound exp
          with
          | Ready next ->
              if skipped <> []
                 && List.exists
                      (function RewriteCond _ -> true | EqCondition _ -> false)
                      next.conditions
              then
                invalid_arg
                  "a premise dependency crosses a rewrite premise";
              translate_prems index bind_membership request_output
                (append result next) []
                (List.rev_append skipped prems)
          | Waiting ->
              if has_rewrite_call index exp then
                invalid_arg "rewrite premise has an unbound input"
              else
                translate_prems index bind_membership request_output result
                  (prem :: skipped) prems
          end
      | LetPr (quants, left, right) ->
          if has_rewrite_call index left || has_rewrite_call index right then
            invalid_arg
              "rewrite-backed call must be an IfPr equality premise";
          begin match translate_letpr index result.bound quants left right with
          | Ready next ->
              translate_prems index bind_membership request_output
                (append result next) []
                (List.rev_append skipped prems)
          | Waiting ->
              translate_prems index bind_membership request_output result
                (prem :: skipped) prems
          end
      | RulePr _ | ElsePr | IterPr _ | NegPr _ ->
          if prem_has_rewrite_call index prem then
            invalid_arg
              "rewrite-backed call must be an IfPr equality premise";
          if skipped <> [] then
            invalid_arg "a premise dependency crosses an effectful premise";
          let next =
            translate_barrier index request_output result.bound prem
          in
          translate_prems index bind_membership request_output
            (append result next) [] prems
      end

let translate_all index ?(bound = []) ?(bind_membership = false)
    ?request_output prems =
  let bound = bind_names Il.Free.Set.empty bound in
  translate_prems index bind_membership request_output
    {conditions = []; bound; otherwise = false} [] prems

let translate_eq_conditions index ?bound prems =
  let result = translate_all index ?bound prems in
  if result.otherwise then invalid_arg "ElsePr belongs to DecD or RelD";
  List.map
    (function
      | EqCondition condition -> condition
      | RewriteCond _ -> invalid_arg "an equation cannot use a rewrite condition")
    result.conditions
