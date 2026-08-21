open Util.Source
open Il.Ast
open Maude_il


let app name args = App (name, args)

let as_sequence_element typ term =
  match typ.it with
  | IterT _ -> app "seq" [term]
  | _ -> term


(* Type iteration *)

let length value = app "len" [value]

let typecheck value element_type =
  BoolCond (app "typecheck" [value; element_type])

let translate_conditions translate_count value element_type iter =
  let check = typecheck value element_type in
  match iter with
  | Opt ->
      [check; BoolCond (app "_<=_" [length value; Const "1"])]
  | List ->
      [check]
  | List1 ->
      [check; BoolCond (app "_<_" [Const "0"; length value])]
  | ListN (count, _) ->
      [check; EqCond (length value, translate_count count)]


(* Bound and captured variables *)

let translate_captures index captures =
  captures
  |> List.map (fun (id, typ) -> Prescan.source_variable index id typ)

let capture_variables index body iterexp =
  Prescan.capture_exp_variables body iterexp
  |> translate_captures index

let term_of_variable (variable : variable) =
  Var variable

let terms_of_variables variables =
  List.map term_of_variable variables

let capture_terms index body iter generators =
  capture_variables index body (iter, generators)
  |> terms_of_variables


(* IterE terms *)

let controls translate_exp = function
  | Opt | List | List1 ->
      []
  | ListN (count, None) ->
      [translate_exp count]
  | ListN (count, Some _) ->
      [translate_exp count; Const "0"]

let translate_term index translate_exp body (iter, generators) =
  match iter, generators with
  | ListN (count, None), [] ->
      app "_^_"
        [ translate_exp body |> as_sequence_element body.note
        ; translate_exp count
        ]
  | (Opt | List | List1), [] ->
      invalid_arg "IterE with Opt, List, or List1 requires a generator"
  | ListN _, _ ->
      let captures = capture_terms index body iter generators in
      let sources = List.map (fun (_, source) -> translate_exp source) generators in
      app (Prescan.iteration_name body)
        (captures @ controls translate_exp iter @ sources)
  | (Opt | List | List1), _ :: _ ->
      let captures = capture_terms index body iter generators in
      let sources = List.map (fun (_, source) -> translate_exp source) generators in
      app (Prescan.iteration_name body) (captures @ sources)


(* Generated helper declarations and equations *)

let count_variable = function
  | ListN _ ->
      Some {name = "ITER-COUNT"; sort = "Nat"; source = false}
  | Opt | List | List1 -> None

let index_variable index = function
  | ListN (_, Some id) ->
      let typ = NumT `NatT $ id.at in
      Some (Prescan.source_variable index id typ)
  | Opt | List | List1 | ListN (_, None) ->
      None

let head_variable index (id, source) =
  match source.note.it with
  | IterT (typ, _) -> Prescan.source_variable index id typ
  | _ -> invalid_arg "iteration generator must have an iteration type"

let tail_variable (id, _) =
  { name = String.uppercase_ascii id.it ^ "S"
  ; sort = "SpectecTerminals"
  ; source = false
  }

let helper_domain captures count index generators =
  List.map (fun (variable : variable) -> variable.sort) captures
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list count)
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list index)
  @ List.map (fun _ -> "SpectecTerminals") generators

let helper_arrow iter generators =
  match iter, generators with
  | List, [_] -> Total
  | (Opt | List | List1 | ListN _), _ -> Partial

let empty_arguments captures count index generators =
  terms_of_variables captures
  @ (match count with None -> [] | Some _ -> [Const "0"])
  @ terms_of_variables (Option.to_list index)
  @ List.map (fun _ -> Const "eps") generators

let source_arguments iter heads tails =
  match iter with
  | Opt ->
      List.map (fun head -> app "_?" [term_of_variable head]) heads
  | List | List1 | ListN _ ->
      List.map2
        (fun head tail ->
          app "_ _" [term_of_variable head; term_of_variable tail])
        heads tails

let step_arguments iter captures count index heads tails =
  terms_of_variables captures
  @ (match count with
     | None -> []
     | Some count -> [app "s" [term_of_variable count]])
  @ terms_of_variables (Option.to_list index)
  @ source_arguments iter heads tails

let next_arguments captures count index tails =
  terms_of_variables captures
  @ terms_of_variables (Option.to_list count)
  @ (match index with
     | None -> []
     | Some index -> [app "s" [term_of_variable index]])
  @ terms_of_variables tails

let translate_statements index translate_exp
    (iteration : Prescan.iteration) =
  let name = iteration.Prescan.name in
  let body = iteration.Prescan.body in
  let iter, generators = iteration.Prescan.iterexp in
  match iter, generators with
  | ListN (_, None), [] ->
      []
  | (Opt | List | List1), [] ->
      invalid_arg "IterE with Opt, List, or List1 requires a generator"
  | (Opt | List | List1 | ListN _), _ ->
      let captures =
        translate_captures index iteration.Prescan.captures
      in
      let count = count_variable iter in
      let iter_index = index_variable index iter in
      let heads = List.map (head_variable index) generators in
      let tails = List.map tail_variable generators in
      let call args = app name args in
      let declaration =
        OpDecl
          { name
          ; domain = helper_domain captures count iter_index generators
          ; codomain = "SpectecTerminals"
          ; arrow = helper_arrow iter generators
          ; attrs = []
          }
      in
      let body_term =
        translate_exp body |> as_sequence_element body.note
      in
      let step_result =
        match iter with
        | Opt ->
            app "_?" [body_term]
        | List | List1 | ListN _ ->
            app "_ _"
              [ body_term
              ; call (next_arguments captures count iter_index tails)
              ]
      in
      let step =
        Eq
          ( call
              (step_arguments iter captures count iter_index heads tails)
          , step_result
          , []
          )
      in
      match iter with
      | List1 ->
          let tail_name = name ^ "-tail" in
          let tail_call args = app tail_name args in
          let tail_declaration =
            OpDecl
              { name = tail_name
              ; domain = helper_domain captures count iter_index generators
              ; codomain = "SpectecTerminals"
              ; arrow = helper_arrow List generators
              ; attrs = []
              }
          in
          let first =
            Eq
              ( call (step_arguments List captures None None heads tails)
              , app "_ _"
                  [ body_term
                  ; tail_call (terms_of_variables (captures @ tails))
                  ]
              , []
              )
          in
          let tail_base =
            Eq
              ( tail_call
                  (terms_of_variables captures
                   @ List.map (fun _ -> Const "eps") generators)
              , Const "eps"
              , []
              )
          in
          let tail_step =
            Eq
              ( tail_call
                  (terms_of_variables captures
                   @ source_arguments List heads tails)
              , app "_ _"
                  [ body_term
                  ; tail_call (terms_of_variables (captures @ tails))
                  ]
              , []
              )
          in
          [declaration; tail_declaration; first; tail_base; tail_step]
      | Opt | List | ListN _ ->
          let base =
            Eq
              ( call (empty_arguments captures count iter_index generators)
              , Const "eps"
              , []
              )
          in
          [declaration; base; step]


(* Whole-script helper materialization *)

let helper_key = function
  | OpDecl declaration :: _ ->
      declaration.name, declaration.domain, declaration.codomain
  | [] ->
      invalid_arg "an iteration helper cannot be empty"
  | _ ->
      invalid_arg "an iteration helper must start with an operator declaration"

let translate_all translate_exp index =
  let add groups iteration =
    let statements =
      translate_statements index translate_exp iteration
    in
    match statements with
    | [] ->
        groups
    | _ ->
        let key = helper_key statements in
        begin match List.assoc_opt key groups with
        | None ->
            (key, statements) :: groups
        | Some previous when previous = statements ->
            groups
        | Some _ ->
            invalid_arg
              ("conflicting iteration helpers named "
               ^ iteration.Prescan.name)
        end
  in
  Prescan.iterations index
  |> List.fold_left add []
  |> List.rev
  |> List.concat_map snd


(* Premise iteration *)

let mixop_has atoms mixop =
  Xl.Mixop.flatten mixop
  |> List.exists (List.exists (fun atom -> List.mem atom.it atoms))

let direct_rule_components mixop exp =
  match Xl.Mixop.arity mixop, exp.it with
  | 0, TupE [] -> Some []
  | 1, VarE id -> Some [id.it]
  | arity, TupE exps when List.length exps = arity ->
      let rec names = function
        | [] -> Some []
        | {it = VarE id; _} :: exps ->
            Option.map (fun names -> id.it :: names) (names exps)
        | _ -> None
      in
      names exps
  | _ -> None

let has_scalar_generator generators =
  List.exists
    (fun (_, source) ->
      match source.note.it with
      | IterT (element, _) ->
          begin match element.it with IterT _ -> false | _ -> true end
      | _ -> false)
    generators

let source_named_premise iteration =
  let body = iteration.Prescan.body in
  let iter, generators = iteration.Prescan.iterexp in
  let non_indexed =
    match iter with
    | Opt | List | List1 | ListN (_, None) -> true
    | ListN (_, Some _) -> false
  in
  match body.it with
  | RulePr (_, [], mixop, exp)
    when non_indexed
         && has_scalar_generator generators
         && mixop_has Xl.Atom.[Turnstile; TurnstileSub; Sub] mixop ->
      let expected =
        List.map (fun (id, _) -> id.it) iteration.Prescan.captures
        @ List.map (fun (id, _) -> id.it) generators
      in
      direct_rule_components mixop exp = Some expected
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> false

let premise_helper_name index iteration =
  match iteration.Prescan.body.it with
  | RulePr (id, _, _, _) when source_named_premise iteration ->
      Prescan.rel_name index id
  | _ -> iteration.Prescan.name

let premise_helper_iter iteration =
  match iteration.Prescan.iterexp with
  | (Opt | List | List1 | ListN (_, None)), _
    when source_named_premise iteration -> List
  | iter, _ -> iter

let premise_helper_call index translate_exp iteration =
  let iter, generators = iteration.Prescan.iterexp in
  let captures =
    translate_captures index iteration.Prescan.captures
    |> terms_of_variables
  in
  let sources = List.map (fun (_, source) -> translate_exp source) generators in
  let sources =
    match iter with
    | Opt when source_named_premise iteration ->
        List.map (fun source -> app "lift" [source]) sources
    | Opt | List | List1 | ListN _ -> sources
  in
  app (premise_helper_name index iteration)
    (captures
     @ (if source_named_premise iteration then []
        else controls translate_exp iter)
     @ sources)

let translate_premise index translate_exp premise =
  match Prescan.premise_iteration index premise with
  | Some iteration ->
      let call =
        premise_helper_call index translate_exp iteration
      in
      let cardinality =
        match iteration.Prescan.iterexp with
        | List1, (_, source) :: _ when source_named_premise iteration ->
            [EqCondition
               (BoolCond
                  (app "_<_" [Const "0"; length (translate_exp source)]))]
        | ListN (count, None), (_, source) :: _
          when source_named_premise iteration ->
            [EqCondition
               (EqCond (length (translate_exp source), translate_exp count))]
        | _ -> []
      in
      EqCondition (BoolCond call) :: cardinality
  | None -> invalid_arg "IterPr is missing from the prescan index"


(* Generated premise helpers *)

let equation left right conditions =
  match conditions with
  | [] -> Eq (left, right, [])
  | _ -> Ceq (left, right, conditions, [])

let premise_local_names iteration =
  let iter, generators = iteration.Prescan.iterexp in
  let indexes =
    match iter with
    | ListN (_, Some id) -> [id.it]
    | Opt | List | List1 | ListN (_, None) -> []
  in
  List.map (fun (id, _) -> id.it) iteration.Prescan.captures
  @ indexes
  @ List.map (fun (id, _) -> id.it) generators

let premise_conditions translate_body iteration =
  let conditions, otherwise =
    translate_body (premise_local_names iteration) iteration.Prescan.body
  in
  if otherwise then invalid_arg "IterPr body cannot contain ElsePr";
  List.map
    (function
      | EqCondition condition -> condition
      | RewriteCond _ ->
          invalid_arg "an IterPr helper cannot contain a rewrite condition")
    conditions

let premise_helper_declaration name domain =
  OpDecl
    { name
    ; domain
    ; codomain = "Bool"
    ; arrow = Partial
    ; attrs = []
    }

let premise_helper_arguments captures count index sources =
  terms_of_variables captures
  @ Option.to_list count
  @ Option.to_list index
  @ sources

let canonical_variables prefix variables =
  List.mapi
    (fun index (variable : variable) ->
      { variable with
        name = prefix ^ string_of_int (index + 1)
      ; source = false
      })
    variables

let translate_premise_statements index translate_body
    (iteration : Prescan.premise_iteration) =
  let name = premise_helper_name index iteration in
  let _, generators = iteration.Prescan.iterexp in
  let iter = premise_helper_iter iteration in
  let captures =
    translate_captures index iteration.Prescan.captures
  in
  let count = count_variable iter in
  let iter_index = index_variable index iter in
  let heads = List.map (head_variable index) generators in
  let tails = List.map tail_variable generators in
  let captures, heads, tails =
    if source_named_premise iteration then
      canonical_variables "CAPTURE" captures,
      canonical_variables "ITEM" heads,
      canonical_variables "TAIL" tails
    else
      captures, heads, tails
  in
  let domain = helper_domain captures count iter_index generators in
  let call name args = app name args in
  let arguments count index sources =
    premise_helper_arguments captures count index sources
  in
  let conditions =
    if source_named_premise iteration then
      [BoolCond
         (app name
            (terms_of_variables captures @ terms_of_variables heads))]
    else
      premise_conditions translate_body iteration
  in
  let declaration = premise_helper_declaration name domain in
  let empty_sources = List.map (fun _ -> Const "eps") generators in
  let base count index =
    Eq (call name (arguments count index empty_sources), Const "true", [])
  in
  let source_patterns iter = source_arguments iter heads tails in
  let step name iter count index next_count next_index next_name =
    let left = call name (arguments count index (source_patterns iter)) in
    let right = call next_name (arguments next_count next_index
                                  (terms_of_variables tails)) in
    equation left right conditions
  in
  match iter, generators with
  | (Opt | List | List1), [] ->
      invalid_arg "IterPr with Opt, List, or List1 requires a generator"
  | Opt, _ ->
      let single =
        equation
          (call name (arguments None None (source_patterns Opt)))
          (Const "true") conditions
      in
      [declaration; base None None; single]
  | List, _ ->
      let step = step name List None None None None name in
      [declaration; base None None; step]
  | List1, _ ->
      let tail_name = name ^ "-tail" in
      let tail_declaration = premise_helper_declaration tail_name domain in
      let first = step name List None None None None tail_name in
      let tail_step = step tail_name List None None None None tail_name in
      let tail_base =
        Eq (call tail_name (arguments None None empty_sources), Const "true", [])
      in
      [declaration; tail_declaration; first; tail_base; tail_step]
  | ListN _, _ ->
      let count = Option.get count in
      let next_index =
        match Option.map term_of_variable iter_index with
        | None -> None
        | Some term -> Some (app "s" [term])
      in
      let step =
        step name List
          (Some (app "s" [term_of_variable count]))
          (Option.map term_of_variable iter_index)
          (Some (term_of_variable count)) next_index name
      in
      [declaration; base (Some (Const "0"))
         (Option.map term_of_variable iter_index); step]

let translate_premise_all translate_body index =
  let add groups iteration =
    let statements =
      translate_premise_statements index translate_body iteration
    in
    let key = helper_key statements in
    match List.assoc_opt key groups with
    | None -> (key, statements) :: groups
    | Some previous when previous = statements -> groups
    | Some _ ->
        let name, _, _ = key in
        invalid_arg ("conflicting IterPr overload named " ^ name)
  in
  Prescan.premise_iterations index
  |> List.fold_left add []
  |> List.rev
  |> List.concat_map snd
