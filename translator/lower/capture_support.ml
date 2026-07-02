open Maude_ir
open Expr_support

let source_free_var_ids exp =
  Il.Free.(free_exp exp).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let type_note_free_var_ids = Expr_support.type_note_free_var_ids

let source_and_note_free_var_ids exp =
  source_free_var_ids exp @ type_note_free_var_ids exp.note
  |> List.sort_uniq String.compare

let prem_free_var_ids prem =
  Il.Free.(free_prem prem).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let short_source_stem source =
  let words =
    Naming.maude_var ~fallback:"BODY" source
    |> String.split_on_char '_'
    |> List.filter (fun word -> word <> "")
  in
  let rec take count length acc = function
    | [] -> List.rev acc
    | word :: words ->
      if count >= 3 then
        List.rev acc
      else
        let next_length =
          length + String.length word + if acc = [] then 0 else 1
        in
        if next_length > 24 && acc <> [] then
          List.rev acc
        else
          take (count + 1) next_length (word :: acc) words
  in
  match take 0 0 [] words with
  | [] -> "BODY"
  | words -> String.concat "_" words

let helper_local_stem origin source =
  Naming.helper_local_var_stem origin ^ "_" ^ short_source_stem source

let helper_local_prefix stem =
  "CAP" ^ stem ^ "X"

let capture_candidates env ids =
  ids
  |> List.fold_left
       (fun captures source_id ->
         match find_var env source_id with
         | Some ({ term = Var _; _ } as binding) ->
           (source_id, binding) :: captures
         | Some _ | None -> captures)
       []
  |> List.rev

let required_capture_candidates env ~required_vars ids =
  ids
  |> List.fold_left
       (fun captures source_id ->
         match find_var env source_id with
         | Some ({ term = Var var_name; _ } as binding)
           when List.mem var_name required_vars ->
           (source_id, var_name, binding) :: captures
         | Some _ | None -> captures)
       []
  |> List.rev

let captured_vars candidates =
  candidates
  |> List.map (fun (_source_id, var_name, _binding) -> var_name)
  |> List.sort_uniq String.compare

let missing_required_vars ~required_vars ~captured_vars =
  required_vars
  |> List.filter (fun var_name -> not (List.mem var_name captured_vars))

let make_required_captures stem candidates =
  let prefix = helper_local_prefix stem in
  candidates
  |> List.mapi (fun index (source_id, _var_name, (binding : binding)) ->
    { Helper.source_id
    ; call_term = binding.term
    ; formal_var = prefix ^ string_of_int index
    ; sort = binding.sort
    ; typ = binding.typ
    })

let make_captures stem candidates =
  let prefix = helper_local_prefix stem in
  candidates
  |> List.mapi (fun index (source_id, (binding : binding)) ->
    { Helper.source_id
    ; call_term = binding.term
    ; formal_var = prefix ^ string_of_int index
    ; sort = binding.sort
    ; typ = binding.typ
    })

let capture_vars captures =
  captures |> List.map (fun capture -> capture.Helper.formal_var)

let capture_env captures =
  captures
  |> List.fold_left
       (fun env capture ->
         add_var env capture.Helper.source_id
           { term = Var capture.Helper.formal_var
           ; sort = capture.Helper.sort
           ; typ = capture.Helper.typ
           })
       empty_env

let filter_used_captures used_vars captures =
  captures
  |> List.filter (fun capture ->
    List.mem capture.Helper.formal_var used_vars)
