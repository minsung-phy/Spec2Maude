open Il.Ast
open Maude_ir
open Util.Source

let source_and_note_free_var_ids = Expr_support.source_and_note_free_var_ids

let prem_free_var_ids prem =
  Il.Free.(free_prem prem).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let iter_source_and_note_free_var_ids = function
  | ListN (count_exp, _) -> source_and_note_free_var_ids count_exp
  | Opt | List | List1 -> []

let rec arg_source_and_note_free_var_ids arg =
  match arg.it with
  | ExpA exp -> source_and_note_free_var_ids exp
  | TypA typ -> typ_source_and_note_free_var_ids typ
  | DefA _ | GramA _ -> []

and typ_source_and_note_free_var_ids typ =
  match typ.it with
  | VarT (_id, args) -> List.concat_map arg_source_and_note_free_var_ids args
  | TupT components ->
    components
    |> List.concat_map (fun (_id, typ) -> typ_source_and_note_free_var_ids typ)
  | IterT (typ, ListN (count_exp, index)) ->
    let ids =
      typ_source_and_note_free_var_ids typ
      @ source_and_note_free_var_ids count_exp
    in
    (match index with
    | None -> ids
    | Some id -> id.it :: ids)
  | IterT (typ, _) -> typ_source_and_note_free_var_ids typ
  | BoolT | NumT _ | TextT -> []

let rec prem_source_and_note_free_var_ids prem =
  let ids =
    match prem.it with
    | RulePr (_, args, _, exp) ->
      source_and_note_free_var_ids exp
      @ List.concat_map arg_source_and_note_free_var_ids args
    | IfPr exp -> source_and_note_free_var_ids exp
    | LetPr (_quants, left, right) ->
      source_and_note_free_var_ids left @ source_and_note_free_var_ids right
    | ElsePr -> []
    | IterPr (body, (iter, generators)) ->
      prem_source_and_note_free_var_ids body
      @ iter_source_and_note_free_var_ids iter
      @ (generators
         |> List.concat_map (fun (_id, source_exp) ->
           source_and_note_free_var_ids source_exp))
    | NegPr body -> prem_source_and_note_free_var_ids body
  in
  ids |> List.sort_uniq String.compare

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
         match Expr_translate.find_var env source_id with
         | Some ({ Expr_translate.term = Var _; _ } as binding) ->
           (source_id, binding) :: captures
         | Some _ | None -> captures)
       []
  |> List.rev

let make_captures stem candidates =
  let prefix = helper_local_prefix stem in
  candidates
  |> List.mapi (fun index (source_id, (binding : Expr_translate.binding)) ->
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
         Expr_translate.add_var env capture.Helper.source_id
           { Expr_translate.term = Var capture.Helper.formal_var
           ; sort = capture.Helper.sort
           ; typ = capture.Helper.typ
           })
       Expr_translate.empty_env

let filter_used_captures used_vars captures =
  captures
  |> List.filter (fun capture ->
    List.mem capture.Helper.formal_var used_vars)
