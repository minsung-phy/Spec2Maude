open Il.Ast
open Maude_ir
open Util.Source

let typ_is_iter = Type_shape.typ_is_iter

let flat_optional_element_typ typ =
  match typ.it with
  | IterT (element_typ, Opt) when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let flat_list_element_typ typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some element_typ
  | _ -> None

let zip_source_descriptor typ =
  match typ.it with
  | IterT (element_typ, (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some (Helper.Source_flat_terminal, element_typ)
  | IterT (({ it = IterT (element_typ, List); _ } as inner_list_typ),
           (List | List1 | ListN _))
    when not (typ_is_iter element_typ) ->
    Some (Helper.Source_nested_seq, inner_list_typ)
  | _ -> None

let typecheck_for_sort sort value typ =
  if sort_name sort = "SpectecTerminals" then
    App ("typecheckSeq", [ value; typ ])
  else
    App ("typecheck", [ value; typ ])

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let lower_with_source_carrier ctx env origin exp =
  match Expr_translate.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    Expr_translate.lower_sequence ctx env origin exp
  | _ -> Expr_translate.lower_value ctx env origin exp
