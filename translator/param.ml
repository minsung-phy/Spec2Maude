open Util.Source
open Il.Ast
open Maude_il


let translate_sort index param =
  match param.it with
  | ExpP (_, typ) -> Term.translate_sort index typ
  | TypP _ -> "SpectecType"
  | DefP _ -> invalid_arg "DefP must be removed by Def.specialize_script"
  | GramP _ -> invalid_arg "GramP is not supported"


let translate_term index param =
  match param.it with
  | ExpP (id, typ) ->
      Var (Prescan.source_variable index id typ)

  | TypP id ->
      Var (Prescan.source_variable_with_sort index id "SpectecType")

  | DefP _ ->
      invalid_arg "DefP must be removed by Def.specialize_script"

  | GramP _ ->
      invalid_arg "GramP is not supported"


let translate_sorts index params =
  List.map (translate_sort index) params

let translate_terms index params =
  List.map (translate_term index) params


let translate_eq_conditions ?(proven = Il.Free.Set.empty) index params =
  params
  |> List.concat_map (fun param ->
       match param.it with
       | ExpP (id, typ) when not (Il.Free.Set.mem id.it proven) ->
           Term.translate_guard_conditions index (translate_term index param) typ

       | ExpP _ | TypP _ | DefP _ -> []

       | GramP _ ->
           invalid_arg "GramP is not supported")


(* DefP positions, used to specialize def parameters away *)

let is_def param =
  match param.it with
  | DefP _ -> true
  | ExpP _ | TypP _ | GramP _ -> false

let def_ids params =
  List.filter_map
    (fun param ->
      match param.it with
      | DefP (id, _, _) -> Some id.it
      | ExpP _ | TypP _ | GramP _ -> None)
    params

(* Splits items at the DefP positions of params. *)
let split_def_positions params items =
  List.fold_right2
    (fun param item (kept, removed) ->
      if is_def param then kept, item :: removed
      else item :: kept, removed)
    params items ([], [])
