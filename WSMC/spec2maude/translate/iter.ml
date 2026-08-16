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


(* Generated helper names *)

let sanitize name =
  name
  |> String.to_seq
  |> Seq.map (function
       | ('a'..'z' | 'A'..'Z' | '0'..'9' | '-') as char -> char
       | _ -> '-')
  |> String.of_seq

let helper_name body =
  match body.it with
  | CallE (id, _) ->
      "map-" ^ sanitize id.it
  | _ ->
      let pos = body.at.left in
      let file = Filename.basename pos.file |> sanitize in
      if file = "" then
        Printf.sprintf "map-exp-%d-%d" pos.line pos.column
      else
        Printf.sprintf "map-%s-%d-%d" file pos.line pos.column


(* Bound and captured variables *)

let index_id = function
  | ListN (_, Some id) -> [id]
  | Opt | List | List1 | ListN (_, None) -> []

let bound_ids iter generators =
  index_id iter @ List.map fst generators

let rec remove_id name = function
  | [] -> []
  | id :: ids when id = name -> ids
  | id :: ids -> id :: remove_id name ids

let capture_variables translate_sort body iter generators =
  let bound = ref (List.map (fun id -> id.it) (bound_ids iter generators)) in
  let captures : variable list ref = ref [] in
  let add id typ =
    if not (List.mem id.it !bound)
       && not
            (List.exists
               (fun (variable : variable) ->
                 variable.name = String.uppercase_ascii id.it)
               !captures)
    then
      captures :=
        { name = String.uppercase_ascii id.it
        ; sort = translate_sort typ
        }
        :: !captures
  in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      match exp.it with
      | VarE id -> add id exp.note
      | _ -> ()

    let scope_enter id _typ =
      bound := id.it :: !bound

    let scope_exit id () =
      bound := remove_id id.it !bound
  end)
  in
  Visitor.exp body;
  List.rev !captures

let term_of_variable (variable : variable) =
  Var variable

let terms_of_variables variables =
  List.map term_of_variable variables

let capture_terms translate_sort body iter generators =
  capture_variables translate_sort body iter generators
  |> terms_of_variables


(* IterE terms *)

let controls translate_exp = function
  | Opt | List | List1 ->
      []
  | ListN (count, None) ->
      [translate_exp count]
  | ListN (count, Some _) ->
      [translate_exp count; Const "0"]

let translate_term translate_exp translate_sort body (iter, generators) =
  match iter, generators with
  | ListN (count, None), [] ->
      app "_^_"
        [ translate_exp body |> as_sequence_element body.note
        ; translate_exp count
        ]
  | (Opt | List | List1), [] ->
      invalid_arg "IterE with Opt, List, or List1 requires a generator"
  | ListN _, _ ->
      let captures = capture_terms translate_sort body iter generators in
      let sources = List.map (fun (_, source) -> translate_exp source) generators in
      app (helper_name body) (captures @ controls translate_exp iter @ sources)
  | (Opt | List | List1), _ :: _ ->
      let captures = capture_terms translate_sort body iter generators in
      let sources = List.map (fun (_, source) -> translate_exp source) generators in
      app (helper_name body) (captures @ sources)


(* Generated helper declarations and equations *)

let count_variable = function
  | ListN _ -> Some {name = "ITER-COUNT"; sort = "Nat"}
  | Opt | List | List1 -> None

let index_variable = function
  | ListN (_, Some id) ->
      Some {name = String.uppercase_ascii id.it; sort = "Nat"}
  | Opt | List | List1 | ListN (_, None) ->
      None

let head_variable translate_sort (id, source) =
  let sort =
    match source.note.it with
    | IterT (typ, _) -> translate_sort typ
    | _ -> invalid_arg "IterE generator must have an iteration type"
  in
  {name = String.uppercase_ascii id.it; sort}

let tail_variable (id, _) =
  { name = String.uppercase_ascii id.it ^ "S"
  ; sort = "SpectecTerminals"
  }

let declare (variable : variable) =
  VarDecl ([variable.name], variable.sort)

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

let helper_variables iter captures count index heads tails =
  List.map declare captures
  @ List.map declare (Option.to_list count)
  @ List.map declare (Option.to_list index)
  @ (List.map2
       (fun head tail ->
         declare head
         :: (match iter with
             | Opt -> []
             | List | List1 | ListN _ -> [declare tail]))
       heads tails
     |> List.concat)

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

let translate_statements translate_exp translate_sort body (iter, generators) =
  match iter, generators with
  | ListN (_, None), [] ->
      []
  | (Opt | List | List1), [] ->
      invalid_arg "IterE with Opt, List, or List1 requires a generator"
  | (Opt | List | List1 | ListN _), _ ->
      let name = helper_name body in
      let captures = capture_variables translate_sort body iter generators in
      let count = count_variable iter in
      let index = index_variable iter in
      let heads = List.map (head_variable translate_sort) generators in
      let tails = List.map tail_variable generators in
      let call args = app name args in
      let declaration =
        OpDecl
          { name
          ; domain = helper_domain captures count index generators
          ; codomain = "SpectecTerminals"
          ; arrow = helper_arrow iter generators
          ; attrs = []
          }
      in
      let variables =
        helper_variables iter captures count index heads tails
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
              ; call (next_arguments captures count index tails)
              ]
      in
      let step =
        Eq
          ( call (step_arguments iter captures count index heads tails)
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
              ; domain = helper_domain captures count index generators
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
          declaration :: tail_declaration :: variables
          @ [first; tail_base; tail_step]
      | Opt | List | ListN _ ->
          let base =
            Eq
              ( call (empty_arguments captures count index generators)
              , Const "eps"
              , []
              )
          in
          declaration :: variables @ [base; step]


(* Nested IterE collection *)

let collect_statements translate_exp translate_sort exp =
  let groups = ref [] in
  let module Visitor = Il.Iter.Make (struct
    include Il.Iter.Skip

    let visit_exp exp =
      match exp.it with
      | IterE (body, iterexp) ->
          groups :=
            translate_statements translate_exp translate_sort body iterexp
            :: !groups
      | _ -> ()
  end)
  in
  Visitor.exp exp;
  !groups |> List.rev |> List.concat
