(* Generated helpers for IterE and IterPr.
 *
 * A translated IterE or IterPr calls a helper (Iter). After all definitions
 * are translated, this module generates the requested helpers: recursive
 * equations over the source sequences (TRANSLATION_MAP.md, section 6). *)

open Util.Source
open Il.Ast
open Maude_il

(* The body of a computed IterE, as a pattern for one element. *)
let bind_body index bound body subject =
  let result =
    Prem.bind_pattern index bound body subject
      "computed IterE body is not invertible"
  in
  result.conditions, result.bound

(* The premise of an IterPr, for one element. A membership premise may
 * choose an element only in the check helper of an execution relation. *)
let translate_body index allow_membership iteration bound body =
  let bind_membership =
    allow_membership
    && Prescan.premise_iteration_binds_membership index iteration
  in
  let result =
    Prem.translate_all index ~bound ~bind_membership ~collect_outputs:false [body]
  in
  result.conditions, result.otherwise, result.bound


(* Helper arguments *)

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

let tail_variable index (id, source) =
  generated_variable
    (String.uppercase_ascii id.it ^ "S") (Prescan.sort_of_typ index source.note)

let helper_domain source_index captures count index generators =
  List.map (fun (variable : variable) -> variable.sort) captures
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list count)
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list index)
  @ List.map
      (fun (_, source) -> Prescan.sort_of_typ source_index source.note)
      generators

let empty_arguments source_index captures count index generators =
  Iter.terms_of_variables captures
  @ (match count with None -> [] | Some _ -> [Const "0"])
  @ Iter.terms_of_variables (Option.to_list index)
  @ List.map
      (fun (_, source) -> Iter.empty_of_typ source_index source.note)
      generators

let step_arguments source_index iter captures count index generators heads tails =
  Iter.terms_of_variables captures
  @ (match count with
     | None -> []
     | Some count -> [Iter.app "s" [Iter.term_of_variable count]])
  @ Iter.terms_of_variables (Option.to_list index)
  @ Iter.source_arguments source_index iter generators heads tails

let next_arguments captures count index tails =
  Iter.terms_of_variables captures
  @ Iter.terms_of_variables (Option.to_list count)
  @ (match index with
     | None -> []
     | Some index -> [Iter.app "s" [Iter.term_of_variable index]])
  @ Iter.terms_of_variables tails

let projector_domain captures count index subject_sort =
  List.map (fun (variable : variable) -> variable.sort) captures
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list count)
  @ List.map
      (fun (variable : variable) -> variable.sort)
      (Option.to_list index)
  @ [subject_sort]

let projector_arguments captures count index subject =
  Iter.terms_of_variables captures
  @ Option.to_list count
  @ Option.to_list index
  @ [subject]

let premise_output_tail_name iteration position =
  snd (List.nth iteration.Prescan.output_names position)


(* IterE helpers *)

let translate_projector_statements index (iteration : Prescan.iteration) =
  let translate_pattern = Prem.translate_pattern_parts index in
  let can_bind_body = Prem.can_bind_computed_pattern index in
  let body = iteration.Prescan.body in
  let iter, generators = iteration.Prescan.iterexp in
  let local_bound = Iter.projector_local_bound iteration.Prescan.captures iter in
  if not (Prescan.requested index iteration.Prescan.name ProjectorHelper
          && Iter.projector_supported index translate_pattern can_bind_body
               local_bound body (iter, generators))
  then [] else
    let name = iteration.Prescan.projector_name in
    let captures = Iter.translate_captures index iteration.Prescan.captures in
    let count = count_variable iter in
    let iter_index = index_variable index iter in
    let result_typ = Iter.iterated_typ body iter in
    let result_representation =
      Prescan.sequence_representation index result_typ
    in
    let heads = List.map (head_variable index) generators in
    let tails =
      generators
      |> List.mapi (fun position (_, source) ->
           generated_variable
             ("PROJECT-COLUMN-" ^ string_of_int (position + 1))
             (Prescan.sort_of_typ index source.note))
    in
    let subject_tail =
      generated_variable "PROJECT-REST" result_representation.sort
    in
    let declaration name iter =
      OpDecl
        { name
        ; domain =
            projector_domain captures (count_variable iter)
              (index_variable index iter) result_representation.sort
        ; codomain =
            if List.length generators = 1
            then
              let _, source = List.hd generators in
              Prescan.sort_of_typ index source.note
            else "SpectecTerminal"
        ; arrow = Partial
        ; attrs = []
        }
    in
    let call name count index subject =
      Iter.app name (projector_arguments captures count index subject)
    in
    let empty =
      Iter.column_term index generators
        (List.map
           (fun (_, source) -> Iter.empty_of_typ index source.note)
           generators)
    in
    let columns = Iter.column_term index generators (Iter.terms_of_variables tails) in
    let next_columns =
      List.map2
        (fun (generator, head) tail ->
          let _, source = generator in
          Iter.sequence_of_typ index source.note
            [Iter.source_head index generator head; Iter.term_of_variable tail])
        (List.combine generators heads) tails
      |> Iter.column_term index generators
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
            bind_body index local_bound body (Iter.term_of_variable value)
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
          Iter.term_of_variable value, guards
    in
    let element = Iter.as_sequence_element index body.note body_pattern in
    let subject =
      Iter.app result_representation.concat
        [element; Iter.term_of_variable subject_tail]
    in
    let recursive name count index next_count next_index =
      Ceq
        ( call name count index subject
        , next_columns
        , body_guards
          @ [MatchCond
               ( columns
               , call name next_count next_index
                   (Iter.term_of_variable subject_tail)
               )]
        , []
        )
    in
    match iter with
    | Opt ->
        [ declaration name Opt
        ; Eq (call name None None (Const result_representation.empty), empty, [])
        ; let left = call name None None (Iter.app "_?" [element]) in
          let right =
            Iter.column_term index generators
              (List.map2
                 (fun generator head ->
                   Iter.app "_?" [Iter.source_head index generator head])
                 generators heads)
          in
          if body_guards = [] then Eq (left, right, [])
          else Ceq (left, right, body_guards, [])
        ]
    | List ->
        [ declaration name List
        ; Eq (call name None None (Const result_representation.empty), empty, [])
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
                   , call tail_name None None (Iter.term_of_variable subject_tail)
                   )]
            , []
            )
        in
        [ declaration name List
        ; declaration tail_name List
        ; first
        ; Eq
            ( call tail_name None None (Const result_representation.empty)
            , empty, [])
        ; recursive tail_name None None None None
        ]
    | ListN _ ->
        let count = Option.get count in
        let current_index = Option.map Iter.term_of_variable iter_index in
        let next_index =
          Option.map (fun index -> Iter.app "s" [index]) current_index
        in
        [ declaration name iter
        ; Eq
            ( call name (Some (Const "0")) current_index
                (Const result_representation.empty)
            , empty, [])
        ; recursive name
            (Some (Iter.app "s" [Iter.term_of_variable count])) current_index
            (Some (Iter.term_of_variable count)) next_index
        ]

let translate_statements index (iteration : Prescan.iteration) =
  let name = iteration.Prescan.name in
  let body = iteration.Prescan.body in
  let iter, generators = iteration.Prescan.iterexp in
  match Iter.identity_source index body (iter, generators) with
  | Some _ -> []
  | None ->
      let forward =
        if not (Prescan.requested index name ForwardHelper) then [] else
        match iter, generators with
        | (Opt | ListN (_, None)), [] ->
            []
        | (List | List1), [] ->
            invalid_arg "IterE with List or List1 requires a generator"
        | (Opt | List | List1 | ListN _), _ ->
            let captures =
              Iter.translate_captures index iteration.Prescan.captures
            in
            let count = count_variable iter in
            let iter_index = index_variable index iter in
            let heads = List.map (head_variable index) generators in
            let tails = List.map (tail_variable index) generators in
            let result_typ = Iter.iterated_typ body iter in
            let result_representation =
              Prescan.sequence_representation index result_typ
            in
            let call args = Iter.app name args in
            let declaration =
              OpDecl
                { name
                ; domain =
                    helper_domain index captures count iter_index generators
                ; codomain = result_representation.sort
                ; arrow = Partial
                ; attrs = []
                }
            in
            let body_term =
              Term.translate_exp index body |> Iter.as_sequence_element index body.note
            in
            let step_result =
              match iter with
              | Opt ->
                  Iter.app "_?" [body_term]
              | List | List1 | ListN _ ->
                  Iter.app result_representation.concat
                    [ body_term
                    ; call (next_arguments captures count iter_index tails)
                    ]
            in
            let step =
              Eq
                ( call
                    (step_arguments index iter captures count iter_index generators
                       heads tails)
                , step_result
                , []
                )
            in
            match iter with
            | List1 ->
                let tail_name = iteration.Prescan.tail_name in
                let tail_call args = Iter.app tail_name args in
                let tail_declaration =
                  OpDecl
                    { name = tail_name
                    ; domain =
                        helper_domain index captures count iter_index generators
                    ; codomain = result_representation.sort
                    ; arrow = Partial
                    ; attrs = []
                    }
                in
                let first =
                  Eq
                    ( call
                        (step_arguments index List captures None None generators
                           heads tails)
                    , Iter.app result_representation.concat
                        [ body_term
                        ; tail_call (Iter.terms_of_variables (captures @ tails))
                        ]
                    , []
                    )
                in
                let tail_base =
                  Eq
                    ( tail_call
                        (Iter.terms_of_variables captures
                         @ List.map
                             (fun (_, source) -> Iter.empty_of_typ index source.note)
                             generators)
                    , Const result_representation.empty
                    , []
                    )
                in
                let tail_step =
                  Eq
                    ( tail_call
                        (Iter.terms_of_variables captures
                         @ Iter.source_arguments index List generators heads tails)
                    , Iter.app result_representation.concat
                        [ body_term
                        ; tail_call (Iter.terms_of_variables (captures @ tails))
                        ]
                    , []
                    )
                in
                [declaration; tail_declaration; first; tail_base; tail_step]
            | Opt | List | ListN _ ->
                let base =
                  Eq
                    ( call
                        (empty_arguments index captures count iter_index
                           generators)
                    , Const result_representation.empty
                    , []
                    )
                in
                [declaration; base; step]
      in
      forward
      @ translate_projector_statements index iteration


(* Whole-script helper materialization *)

(* Generating a helper body can request another helper, including one that
 * was already visited. Regenerate until no helper received a request after
 * it was visited. [status] reads the requests of one helper. *)
let generate_requested status add helpers =
  let rec generate () =
    let visited = ref [] in
    let groups =
      List.fold_left
        (fun groups helper ->
          visited := (helper, status helper) :: !visited;
          add groups helper)
        [] helpers
    in
    if List.exists (fun (helper, before) -> before <> status helper) !visited
    then generate ()
    else List.concat_map snd (List.rev groups)
  in
  generate ()

let helper_key = function
  | OpDecl declaration :: _ ->
      declaration.name, declaration.domain, declaration.codomain
  | [] ->
      invalid_arg "an iteration helper cannot be empty"
  | _ ->
      invalid_arg "an iteration helper must start with an operator declaration"

let translate_all index =
  let add groups iteration =
    let statements =
      translate_statements index iteration
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
  let status (iteration : Prescan.iteration) =
    Prescan.requested index iteration.name ForwardHelper,
    Prescan.requested index iteration.name ProjectorHelper
  in
  generate_requested status add (Prescan.iterations index)


(* Generated premise helpers *)

let equation left right conditions =
  match conditions with
  | [] -> Eq (left, right, [])
  | _ -> Ceq (left, right, conditions, [])

let premise_local_names without iteration =
  let iter, generators = iteration.Prescan.iterexp in
  let indexes =
    match iter with
    | ListN (_, Some id) -> [id.it]
    | Opt | List | List1 | ListN (_, None) -> []
  in
  List.filter_map
    (function
      | Prescan.VariableCapture (id, _) -> Some id.it
      | Prescan.TypeCapture _ -> None)
    iteration.Prescan.captures
  @ indexes
  @ List.filter_map
      (fun (position, (id, _)) ->
        if Some position = without then None else Some id.it)
      (List.mapi (fun position generator -> position, generator) generators)

let premise_conditions index without iteration =
  let conditions, otherwise, bound =
    translate_body index (Option.is_none without) iteration
      (premise_local_names without iteration) iteration.Prescan.body
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
  Iter.terms_of_variables captures
  @ Option.to_list count
  @ Option.to_list index
  @ sources

type premise_mode = Check | Collect of int

let translate_premise_statements index
    (iteration : Prescan.premise_iteration) mode =
  let iter, all_generators = iteration.Prescan.iterexp in
  let name, tail_name, generators, output, codomain, without =
    match mode with
    | Check ->
        Iter.premise_helper_name iteration, iteration.Prescan.tail_name,
        all_generators, None, "Bool", None
    | Collect position ->
        let generator = List.nth all_generators position in
        let _, source = generator in
        Iter.premise_output_name iteration position,
        premise_output_tail_name iteration position,
        Prescan.remove_at position all_generators,
        Some (generator, head_variable index generator),
        Prescan.sort_of_typ index source.note, Some position
  in
  let captures =
    Iter.translate_captures index iteration.Prescan.captures
  in
  let count = count_variable iter in
  let iter_index = index_variable index iter in
  let heads = List.map (head_variable index) generators in
  let tails = List.map (tail_variable index) generators in
  let domain = helper_domain index captures count iter_index generators in
  let call name args = Iter.app name args in
  let arguments count index sources =
    premise_helper_arguments captures count index sources
  in
  let conditions, bound =
    premise_conditions index without iteration
  in
  begin match output with
  | Some ((id, _), _) when not (Il.Free.Set.mem id.it bound) ->
      invalid_arg "IterPr output helper body does not bind its output"
  | None | Some _ -> ()
  end;
  let declaration = premise_helper_declaration name domain codomain in
  let empty_sources =
    List.map (fun (_, source) -> Iter.empty_of_typ index source.note) generators
  in
  let empty_result =
    match output with
    | None -> Const "true"
    | Some ((_, source), _) -> Iter.empty_of_typ index source.note
  in
  let base count index =
    Eq (call name (arguments count index empty_sources), empty_result, [])
  in
  let source_patterns iter =
    Iter.source_arguments index iter generators heads tails
  in
  let extend result =
    match output with
    | None -> result
    | Some ((_, source) as generator, head) ->
        Iter.sequence_of_typ index source.note
          [Iter.source_head index generator head; result]
  in
  let step name iter count index next_count next_index next_name =
    let left = call name (arguments count index (source_patterns iter)) in
    let right =
      call next_name (arguments next_count next_index (Iter.terms_of_variables tails))
    in
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
            Iter.app "_?" [Iter.source_head index generator head]
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
        Option.map (fun variable -> Iter.app "s" [Iter.term_of_variable variable]) iter_index
      in
      let step =
        step name List
          (Some (Iter.app "s" [Iter.term_of_variable count]))
          (Option.map Iter.term_of_variable iter_index)
          (Some (Iter.term_of_variable count)) next_index name
      in
      [declaration; base (Some (Const "0"))
         (Option.map Iter.term_of_variable iter_index); step]

let translate_premise_all index =
  let add groups iteration =
    let name = iteration.Prescan.name in
    let statements =
      (if Prescan.requested index name CheckHelper
       then [translate_premise_statements index iteration Check]
       else [])
      @ List.map
           (fun position ->
             translate_premise_statements index iteration
               (Collect position))
           (Prescan.requested_outputs index name)
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
  let status (iteration : Prescan.premise_iteration) =
    Prescan.requested index iteration.name CheckHelper
  in
  generate_requested status add (Prescan.premise_iterations index)
