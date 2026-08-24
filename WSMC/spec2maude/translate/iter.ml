open Util.Source
open Il.Ast
open Maude_il


let app name args = App (name, args)

let rec sequence = function
  | [] -> Const "eps"
  | [term] -> term
  | term :: terms -> app "_ _" [term; sequence terms]

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
  |> List.map (function
       | Prescan.VariableCapture (id, typ) ->
           Prescan.source_variable index id typ
       | Prescan.DefinitionCapture parameter ->
           Prescan.definition_variable index parameter)

let captures index body =
  match Prescan.iteration index body with
  | Some iteration -> iteration.Prescan.captures
  | None -> invalid_arg "IterE is missing from the prescan index"

let capture_variables index body =
  captures index body |> translate_captures index

let term_of_variable (variable : variable) =
  Var variable

let terms_of_variables variables =
  List.map term_of_variable variables

let capture_terms index body =
  capture_variables index body |> terms_of_variables


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
      app "repeatSeq"
        [ translate_exp count
        ; translate_exp body |> as_sequence_element body.note
        ]
  | (Opt | List | List1), [] ->
      invalid_arg "IterE with Opt, List, or List1 requires a generator"
  | ListN _, _ ->
      let captures = capture_terms index body in
      let sources = List.map (fun (_, source) -> translate_exp source) generators in
      app (Prescan.iteration_name index body)
        (captures @ controls translate_exp iter @ sources)
  | (Opt | List | List1), _ :: _ ->
      let captures = capture_terms index body in
      let sources = List.map (fun (_, source) -> translate_exp source) generators in
      app (Prescan.iteration_name index body) (captures @ sources)


(* Generated helper declarations and equations *)

let count_variable = function
  | ListN _ ->
      Some (generated_variable "ITER-COUNT" "Nat")
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
  generated_variable
    (String.uppercase_ascii id.it ^ "S") "SpectecTerminals"

let helper_domain captures count index generators =
  List.map (fun (variable : variable) -> variable.sort) captures
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list count)
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list index)
  @ List.map (fun _ -> "SpectecTerminals") generators

let empty_arguments captures count index generators =
  terms_of_variables captures
  @ (match count with None -> [] | Some _ -> [Const "0"])
  @ terms_of_variables (Option.to_list index)
  @ List.map (fun _ -> Const "eps") generators

let generator_element (_, source) =
  match source.note.it with
  | IterT (element, _) -> element
  | _ -> invalid_arg "iteration generator must have an iteration type"

let source_head generator head =
  term_of_variable head
  |> as_sequence_element (generator_element generator)

let source_arguments iter generators heads tails =
  match iter with
  | Opt ->
      List.map2
        (fun generator head -> app "_?" [source_head generator head])
        generators heads
  | List | List1 | ListN _ ->
      List.map2
        (fun (generator, head) tail ->
          app "_ _" [source_head generator head; term_of_variable tail])
        (List.combine generators heads) tails

let step_arguments iter captures count index generators heads tails =
  terms_of_variables captures
  @ (match count with
     | None -> []
     | Some count -> [app "s" [term_of_variable count]])
  @ terms_of_variables (Option.to_list index)
  @ source_arguments iter generators heads tails

let next_arguments captures count index tails =
  terms_of_variables captures
  @ terms_of_variables (Option.to_list count)
  @ (match index with
     | None -> []
     | Some index -> [app "s" [term_of_variable index]])
  @ terms_of_variables tails

let rec identity_body_id exp =
  match exp.it with
  | VarE id -> Some id
  | IterE (inner, (List, [(binder, source)])) ->
      begin match identity_body_id inner, source.it with
      | Some inner_id, VarE source_id when inner_id.it = binder.it ->
          Some source_id
      | _ -> None
      end
  | _ -> None

let identity_source body generators =
  match identity_body_id body, generators with
  | Some body_id, [(generator_id, source)]
    when body_id.it = generator_id.it -> Some source
  | _ -> None

let translate_identity_pattern translate_pattern body (iter, generators) =
  match identity_source body generators with
  | None -> None
  | Some source ->
      begin match translate_pattern source with
      | None -> None
      | Some (term, guards) ->
          let cardinality =
            match iter with
            | Opt ->
                Some [BoolCond (app "_<=_" [length term; Const "1"])]
            | List -> Some []
            | List1 ->
                Some [BoolCond (app "_<_" [Const "0"; length term])]
            | ListN (count, _) ->
                begin match translate_pattern count with
                | Some (count, count_guards) ->
                    Some (MatchCond (count, length term) :: count_guards)
                | None -> None
                end
          in
          Option.map (fun cardinality -> term, guards @ cardinality)
            cardinality
      end

let projector_local_bound captures iter =
  let bound =
    List.fold_left
      (fun bound -> function
        | Prescan.VariableCapture (id, _) -> Il.Free.Set.add id.it bound
        | Prescan.DefinitionCapture _ -> bound)
      Il.Free.Set.empty captures
  in
  let bound =
    match iter with
    | ListN (count, _) ->
        Il.Free.Set.union bound Il.Free.(free_exp count).varid
    | Opt | List | List1 -> bound
  in
  match iter with
  | ListN (_, Some id) -> Il.Free.Set.add id.it bound
  | Opt | List | List1 | ListN (_, None) -> bound

let projector_supported translate_pattern can_bind_body bound body generators =
  generators <> []
  && identity_source body generators = None
  && (Option.is_some (translate_pattern body) || can_bind_body bound body)
  && List.for_all
       (fun (id, _) -> Il.Free.Set.mem id.it Il.Free.(free_exp body).varid)
       generators

let projector_domain captures count index =
  List.map (fun (variable : variable) -> variable.sort) captures
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list count)
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list index)
  @ ["SpectecTerminals"]

let column_term generators columns =
  match generators, columns with
  | [_], [column] -> column
  | _, _ ->
      List.map2
        (fun (_, source) column -> as_sequence_element source.note column)
        generators columns
      |> sequence
      |> fun columns -> app "tuple" [columns]

let projector_arguments captures count index subject =
  terms_of_variables captures
  @ Option.to_list count
  @ Option.to_list index
  @ [subject]

let translate_projector_statements index translate_pattern can_bind_body bind_body
    (iteration : Prescan.iteration) =
  let body = iteration.Prescan.body in
  let iter, generators = iteration.Prescan.iterexp in
  let local_bound = projector_local_bound iteration.Prescan.captures iter in
  if not (Prescan.projector_requested index body
          && projector_supported translate_pattern can_bind_body
               local_bound body generators)
  then [] else
    let name = iteration.Prescan.projector_name in
    let captures = translate_captures index iteration.Prescan.captures in
    let count = count_variable iter in
    let iter_index = index_variable index iter in
    let heads = List.map (head_variable index) generators in
    let tails =
      generators
      |> List.mapi (fun position _ ->
           generated_variable
             ("PROJECT-COLUMN-" ^ string_of_int (position + 1))
             "SpectecTerminals")
    in
    let subject_tail =
      generated_variable "PROJECT-REST" "SpectecTerminals"
    in
    let declaration name iter =
      OpDecl
        { name
        ; domain = projector_domain captures (count_variable iter)
                     (index_variable index iter)
        ; codomain =
            if List.length generators = 1
            then "SpectecTerminals" else "SpectecTerminal"
        ; arrow = Partial
        ; attrs = []
        }
    in
    let call name count index subject =
      app name (projector_arguments captures count index subject)
    in
    let empty = column_term generators (List.map (fun _ -> Const "eps") generators) in
    let columns = column_term generators (terms_of_variables tails) in
    let next_columns =
      List.map2
        (fun (generator, head) tail ->
          app "_ _" [source_head generator head; term_of_variable tail])
        (List.combine generators heads) tails
      |> column_term generators
    in
    let body_pattern, body_guards =
      match translate_pattern body with
      | Some pattern -> pattern
      | None ->
          let value =
            generated_variable "PROJECT-ELEMENT"
              (Prescan.sort_of_typ index body.note)
          in
          let conditions, bound =
            bind_body local_bound body (term_of_variable value)
          in
          if not
               (List.for_all
                  (fun (id, _) -> Il.Free.Set.mem id.it bound)
                  generators)
          then invalid_arg "computed IterE body does not bind every generator";
          let guards =
            List.map
              (function
                | EqCondition condition -> condition
                | RewriteCond _ ->
                    invalid_arg
                      "an IterE projector cannot use a rewrite condition")
              conditions
          in
          term_of_variable value, guards
    in
    let element = as_sequence_element body.note body_pattern in
    let subject =
      app "_ _" [element; term_of_variable subject_tail]
    in
    let recursive name count index next_count next_index =
      Ceq
        ( call name count index subject
        , next_columns
        , body_guards
          @ [MatchCond
               ( columns
               , call name next_count next_index
                   (term_of_variable subject_tail)
               )]
        , []
        )
    in
    match iter with
    | Opt ->
        [ declaration name Opt
        ; Eq (call name None None (Const "eps"), empty, [])
        ; let left = call name None None (app "_?" [element]) in
          let right =
            column_term generators
              (List.map2
                 (fun generator head ->
                   app "_?" [source_head generator head])
                 generators heads)
          in
          if body_guards = [] then Eq (left, right, [])
          else Ceq (left, right, body_guards, [])
        ]
    | List ->
        [ declaration name List
        ; Eq (call name None None (Const "eps"), empty, [])
        ; recursive name None None None None
        ]
    | List1 ->
        let tail_name = iteration.Prescan.projector_tail_name in
        let first =
          Ceq
            ( call name None None subject
            , next_columns
            , body_guards
              @ [MatchCond
                   ( columns
                   , call tail_name None None (term_of_variable subject_tail)
                   )]
            , []
            )
        in
        [ declaration name List
        ; declaration tail_name List
        ; first
        ; Eq (call tail_name None None (Const "eps"), empty, [])
        ; recursive tail_name None None None None
        ]
    | ListN _ ->
        let count = Option.get count in
        let current_index = Option.map term_of_variable iter_index in
        let next_index =
          Option.map (fun index -> app "s" [index]) current_index
        in
        [ declaration name iter
        ; Eq
            ( call name (Some (Const "0")) current_index (Const "eps")
            , empty, [])
        ; recursive name
            (Some (app "s" [term_of_variable count])) current_index
            (Some (term_of_variable count)) next_index
        ]

let rec translate_source_patterns translate_pattern = function
  | [] -> Some ([], [])
  | (_, source) :: generators ->
      begin match
        translate_pattern source,
        translate_source_patterns translate_pattern generators
      with
      | Some (term, guards), Some (terms, remaining_guards) ->
          Some (term :: terms, guards @ remaining_guards)
      | None, _ | _, None -> None
      end

let pattern_count translate_pattern translate_exp known subject = function
  | ListN (count, _) when known count ->
      Some (translate_exp count, [])
  | ListN (({it = VarE _; _} as count), _) ->
      translate_pattern count
      |> Option.map (fun (pattern, guards) ->
           length subject,
           MatchCond (pattern, length subject) :: guards)
  | ListN _ -> None
  | Opt | List | List1 -> Some (Const "0", [])

let identity_cardinality translate_exp known subject = function
  | Opt ->
      [BoolCond (app "_<=_" [length subject; Const "1"])]
  | List -> []
  | List1 ->
      [BoolCond (app "_<_" [Const "0"; length subject])]
  | ListN (count, _) when known count ->
      [EqCond (length subject, translate_exp count)]
  | ListN _ -> []

let translate_pattern index translate_source_pattern translate_exp known is_bound
    can_bind_body body (iter, generators) subject =
  let captures = captures index body in
  let count_variables =
    match iter with
    | ListN (count, _) when not (known count) ->
        Il.Free.(free_exp count).varid
    | Opt | List | List1 | ListN _ -> Il.Free.Set.empty
  in
  let captures_ready () =
    List.for_all
      (function
        | Prescan.VariableCapture (id, _) ->
            is_bound id.it || Il.Free.Set.mem id.it count_variables
        | Prescan.DefinitionCapture _ -> true)
      captures
  in
  match
    translate_source_patterns translate_source_pattern generators
  with
  | None -> None
  | Some (source_patterns, source_guards) ->
      begin match identity_source body generators, source_patterns with
      | Some _, [source_pattern] ->
          begin match pattern_count translate_source_pattern translate_exp
                        known subject iter with
          | None -> None
          | Some (_, count_conditions) ->
              if not (captures_ready ()) then
                invalid_arg "IterE pattern has an unbound capture";
              Some
                ( count_conditions
                  @ (MatchCond (source_pattern, subject) :: source_guards)
                  @ identity_cardinality translate_exp known subject iter)
          end
      | None, _ when
          projector_supported translate_source_pattern can_bind_body
            (projector_local_bound captures iter)
            body generators ->
          begin match pattern_count translate_source_pattern translate_exp
                        known subject iter with
          | None -> None
          | Some (count, count_conditions) ->
              if not (captures_ready ()) then
                invalid_arg "IterE pattern has an unbound capture";
              let captures = capture_terms index body in
              let controls =
                match iter with
                | Opt | List | List1 -> []
                | ListN (_, None) -> [count]
                | ListN (_, Some _) -> [count; Const "0"]
              in
              let projected =
        app (Prescan.projector_name index body)
          (captures @ controls @ [subject])
              in
              let forward =
                translate_term index translate_exp body (iter, generators)
              in
              Some
                ( count_conditions
                  @ (MatchCond
                       (column_term generators source_patterns, projected)
                     :: source_guards)
                  @ [EqCond (forward, subject)])
          end
      | Some _, _ | None, _ -> None
      end

let translate_statements index translate_pattern can_bind_body bind_body translate_exp
    (iteration : Prescan.iteration) =
  let name = iteration.Prescan.name in
  let body = iteration.Prescan.body in
  let iter, generators = iteration.Prescan.iterexp in
  let forward =
    match iter, generators with
    | (Opt | ListN (_, None)), [] ->
      []
    | (List | List1), [] ->
      invalid_arg "IterE with List or List1 requires a generator"
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
          ; arrow = Partial
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
              (step_arguments iter captures count iter_index generators heads tails)
          , step_result
          , []
          )
      in
      match iter with
      | List1 ->
          let tail_name = iteration.Prescan.tail_name in
          let tail_call args = app tail_name args in
          let tail_declaration =
            OpDecl
              { name = tail_name
              ; domain = helper_domain captures count iter_index generators
              ; codomain = "SpectecTerminals"
              ; arrow = Partial
              ; attrs = []
              }
          in
          let first =
            Eq
              ( call
                  (step_arguments List captures None None generators heads tails)
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
                   @ source_arguments List generators heads tails)
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
  in
  forward
  @ translate_projector_statements index translate_pattern can_bind_body
      bind_body iteration


(* Whole-script helper materialization *)

let helper_key = function
  | OpDecl declaration :: _ ->
      declaration.name, declaration.domain, declaration.codomain
  | [] ->
      invalid_arg "an iteration helper cannot be empty"
  | _ ->
      invalid_arg "an iteration helper must start with an operator declaration"

let translate_all translate_pattern can_bind_body bind_body translate_exp index =
  let add groups iteration =
    let statements =
      translate_statements index translate_pattern can_bind_body bind_body
        translate_exp iteration
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

let premise_helper_name iteration = iteration.Prescan.name

let premise_output_name iteration position =
  fst (List.nth iteration.Prescan.output_names position)

let premise_output_tail_name iteration position =
  snd (List.nth iteration.Prescan.output_names position)

let remove_at position items =
  items
  |> List.mapi (fun index item -> index, item)
  |> List.filter_map (fun (index, item) ->
       if index = position then None else Some item)

let premise_output_possible iteration position =
  let iter, generators = iteration.Prescan.iterexp in
  position >= 0 && position < List.length generators
  && match iter with ListN _ -> true | _ -> List.length generators > 1

let premise_helper_call index translate_exp iteration =
  let iter, generators = iteration.Prescan.iterexp in
  let captures =
    translate_captures index iteration.Prescan.captures
    |> terms_of_variables
  in
  let sources = List.map (fun (_, source) -> translate_exp source) generators in
  app (premise_helper_name iteration)
    (captures @ controls translate_exp iter @ sources)

let premise_output_call index translate_exp iteration position =
  let iter, generators = iteration.Prescan.iterexp in
  let captures =
    translate_captures index iteration.Prescan.captures
    |> terms_of_variables
  in
  let sources =
    generators |> remove_at position
    |> List.map (fun (_, source) -> translate_exp source)
  in
  app (premise_output_name iteration position)
    (captures @ controls translate_exp iter @ sources)

let translate_premise index translate_exp premise =
  match Prescan.premise_iteration index premise with
  | Some iteration ->
      let call =
        premise_helper_call index translate_exp iteration
      in
      [EqCondition (BoolCond call)]
  | None -> invalid_arg "IterPr is missing from the prescan index"


(* Generated premise helpers *)

let equation left right conditions =
  match conditions with
  | [] -> Eq (left, right, [])
  | _ -> Ceq (left, right, conditions, [])

let premise_local_names ?without iteration =
  let iter, generators = iteration.Prescan.iterexp in
  let indexes =
    match iter with
    | ListN (_, Some id) -> [id.it]
    | Opt | List | List1 | ListN (_, None) -> []
  in
  List.filter_map
    (function
      | Prescan.VariableCapture (id, _) -> Some id.it
      | Prescan.DefinitionCapture _ -> None)
    iteration.Prescan.captures
  @ indexes
  @ List.filter_map
      (fun (position, (id, _)) ->
        if Some position = without then None else Some id.it)
      (List.mapi (fun position generator -> position, generator) generators)

let premise_conditions translate_body ?without iteration =
  let conditions, otherwise, bound =
    translate_body (Option.is_none without) iteration
      (premise_local_names ?without iteration) iteration.Prescan.body
  in
  if otherwise then invalid_arg "IterPr body cannot contain ElsePr";
  ( List.map
      (function
        | EqCondition condition -> condition
        | RewriteCond _ ->
            invalid_arg "an IterPr helper cannot contain a rewrite condition")
      conditions
  , bound
  )

let premise_helper_declaration name domain codomain =
  OpDecl
    { name
    ; domain
    ; codomain
    ; arrow = Partial
    ; attrs = []
    }

let premise_helper_arguments captures count index sources =
  terms_of_variables captures
  @ Option.to_list count
  @ Option.to_list index
  @ sources

type premise_mode = Check | Collect of int

let translate_premise_statements index translate_body
    (iteration : Prescan.premise_iteration) mode =
  let iter, all_generators = iteration.Prescan.iterexp in
  let name, tail_name, generators, output, codomain, without =
    match mode with
    | Check ->
        premise_helper_name iteration, iteration.Prescan.tail_name,
        all_generators, None, "Bool", None
    | Collect position ->
        let generator = List.nth all_generators position in
        premise_output_name iteration position,
        premise_output_tail_name iteration position,
        remove_at position all_generators,
        Some (generator, head_variable index generator),
        "SpectecTerminals", Some position
  in
  let captures =
    translate_captures index iteration.Prescan.captures
  in
  let count = count_variable iter in
  let iter_index = index_variable index iter in
  let heads = List.map (head_variable index) generators in
  let tails = List.map tail_variable generators in
  let domain = helper_domain captures count iter_index generators in
  let call name args = app name args in
  let arguments count index sources =
    premise_helper_arguments captures count index sources
  in
  let conditions, bound =
    premise_conditions translate_body ?without iteration
  in
  begin match output with
  | Some ((id, _), _) when not (Il.Free.Set.mem id.it bound) ->
      invalid_arg "IterPr output helper body does not bind its output"
  | None | Some _ -> ()
  end;
  let declaration = premise_helper_declaration name domain codomain in
  let empty_sources = List.map (fun _ -> Const "eps") generators in
  let empty_result =
    match output with None -> Const "true" | Some _ -> Const "eps"
  in
  let base count index =
    Eq (call name (arguments count index empty_sources), empty_result, [])
  in
  let source_patterns iter = source_arguments iter generators heads tails in
  let extend result =
    match output with
    | None -> result
    | Some (generator, head) ->
        app "_ _" [source_head generator head; result]
  in
  let step name iter count index next_count next_index next_name =
    let left = call name (arguments count index (source_patterns iter)) in
    let right = call next_name (arguments next_count next_index
                                  (terms_of_variables tails)) in
    equation left (extend right) conditions
  in
  match iter, generators with
  | (Opt | List | List1), [] ->
      invalid_arg "IterPr with Opt, List, or List1 requires a generator"
  | Opt, _ ->
      let result =
        match output with
        | None -> Const "true"
        | Some (generator, head) ->
            app "_?" [source_head generator head]
      in
      let single =
        equation
          (call name (arguments None None (source_patterns Opt)))
          result conditions
      in
      [declaration; base None None; single]
  | List, _ ->
      let step = step name List None None None None name in
      [declaration; base None None; step]
  | List1, _ ->
      let tail_declaration =
        premise_helper_declaration tail_name domain codomain
      in
      let first = step name List None None None None tail_name in
      let tail_step = step tail_name List None None None None tail_name in
      let tail_base =
        Eq
          (call tail_name (arguments None None empty_sources), empty_result, [])
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

let translate_premise_all translate_body index outputs =
  let add groups iteration =
    let output_positions =
      outputs
      |> List.filter_map (fun (requested_name, position) ->
           if requested_name = iteration.Prescan.name
           then Some position else None)
      |> List.sort_uniq compare
    in
    let statements =
      translate_premise_statements index translate_body iteration Check
      :: List.map
           (fun position ->
             translate_premise_statements index translate_body iteration
               (Collect position))
           output_positions
    in
    List.fold_left
      (fun groups statements ->
        let key = helper_key statements in
        match List.assoc_opt key groups with
        | None -> (key, statements) :: groups
        | Some previous when previous = statements -> groups
        | Some _ ->
            let name, _, _ = key in
            invalid_arg ("conflicting IterPr overload named " ^ name))
      groups statements
  in
  Prescan.premise_iterations index
  |> List.fold_left add []
  |> List.rev
  |> List.concat_map snd
