open Il.Ast
open Util.Source

let exp_ids exp =
  Il.Free.(free_exp exp).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let rec type_note_ids typ =
  let child_ids =
    match typ.it with
    | VarT (_id, args) -> args |> List.concat_map arg_note_ids
    | BoolT | NumT _ | TextT -> []
    | TupT fields ->
      fields
      |> List.concat_map (fun (id, typ) ->
        id.it :: type_note_ids typ)
    | IterT (inner_typ, iter) ->
      type_note_ids inner_typ @ iter_note_ids iter
  in
  Il.Free.(free_typ typ).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> fun ids -> ids @ child_ids
  |> List.sort_uniq String.compare

and iter_note_ids = function
  | ListN (count_exp, _) -> expression_note_ids count_exp
  | Opt | List | List1 -> []

and expression_note_ids exp =
  let child_ids =
    match exp.it with
    | VarE _ | BoolE _ | NumE _ | TextE _ -> []
    | UnE (_, _, inner)
    | LiftE inner
    | LenE inner
    | ProjE (inner, _)
    | TheE inner
    | DotE (inner, _)
    | CaseE (_, inner)
    | UncaseE (inner, _)
    | CvtE (inner, _, _) ->
      expression_note_ids inner
    | BinE (_, _, left, right)
    | CmpE (_, _, left, right)
    | IdxE (left, right)
    | CompE (left, right)
    | MemE (left, right)
    | CatE (left, right) ->
      expression_note_ids left @ expression_note_ids right
    | SliceE (base, first, last) | IfE (base, first, last) ->
      expression_note_ids base
      @ expression_note_ids first
      @ expression_note_ids last
    | OptE None -> []
    | OptE (Some inner) -> expression_note_ids inner
    | TupE fields | ListE fields ->
      fields |> List.concat_map expression_note_ids
    | UpdE (base, path, value) | ExtE (base, path, value) ->
      expression_note_ids base
      @ path_note_ids path
      @ expression_note_ids value
    | StrE fields ->
      fields
      |> List.concat_map (fun (_atom, field) ->
        expression_note_ids field)
    | CallE (_id, args) ->
      args |> List.concat_map arg_note_ids
    | IterE (body, (_iter, sources)) ->
      expression_note_ids body
      @ (sources
         |> List.concat_map (fun (_id, source) ->
           expression_note_ids source))
    | SubE (inner, from_typ, to_typ) ->
      expression_note_ids inner
      @ type_note_ids from_typ
      @ type_note_ids to_typ
  in
  type_note_ids exp.note @ child_ids
  |> List.sort_uniq String.compare

and path_note_ids path =
  let child_ids =
    match path.it with
    | RootP -> []
    | IdxP (inner, index) ->
      path_note_ids inner @ expression_note_ids index
    | SliceP (inner, first, last) ->
      path_note_ids inner
      @ expression_note_ids first
      @ expression_note_ids last
    | DotP (inner, _) -> path_note_ids inner
  in
  type_note_ids path.note @ child_ids
  |> List.sort_uniq String.compare

and arg_note_ids arg =
  match arg.it with
  | ExpA exp -> expression_note_ids exp
  | TypA typ -> type_note_ids typ
  | DefA _ | GramA _ -> []

let exp_and_note_ids exp =
  exp_ids exp @ expression_note_ids exp
  |> List.sort_uniq String.compare

let prem_ids prem =
  Il.Free.(free_prem prem).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let iter_exp_and_note_ids = function
  | ListN (count_exp, _) -> exp_and_note_ids count_exp
  | Opt | List | List1 -> []

let rec arg_exp_and_note_ids arg =
  match arg.it with
  | ExpA exp -> exp_and_note_ids exp
  | TypA typ -> typ_exp_and_note_ids typ
  | DefA _ | GramA _ -> []

and typ_exp_and_note_ids typ =
  match typ.it with
  | VarT (_id, args) -> List.concat_map arg_exp_and_note_ids args
  | TupT components ->
    components
    |> List.concat_map (fun (_id, typ) -> typ_exp_and_note_ids typ)
  | IterT (typ, ListN (count_exp, index)) ->
    let ids = typ_exp_and_note_ids typ @ exp_and_note_ids count_exp in
    (match index with
    | None -> ids
    | Some id -> id.it :: ids)
  | IterT (typ, _) -> typ_exp_and_note_ids typ
  | BoolT | NumT _ | TextT -> []

let rec prem_and_note_ids prem =
  let ids =
    match prem.it with
    | RulePr (_, args, _, exp) ->
      exp_and_note_ids exp @ List.concat_map arg_exp_and_note_ids args
    | IfPr exp -> exp_and_note_ids exp
    | LetPr (_quants, left, right) ->
      exp_and_note_ids left @ exp_and_note_ids right
    | ElsePr -> []
    | IterPr (body, (iter, generators)) ->
      prem_and_note_ids body
      @ iter_exp_and_note_ids iter
      @ (generators
         |> List.concat_map (fun (_id, source_exp) ->
           exp_and_note_ids source_exp))
    | NegPr body -> prem_and_note_ids body
  in
  ids |> List.sort_uniq String.compare
