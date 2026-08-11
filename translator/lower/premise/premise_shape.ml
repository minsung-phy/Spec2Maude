open Maude_ir
open Util.Source

let flat_optional_element_typ = Iteration_shape.flat_optional_element
let flat_list_element_typ = Iteration_shape.flat_repeated_element

let zip_source_descriptor typ =
  match Iteration_shape.flat_repeated_element typ with
  | Some element_typ ->
    Some (Helper_request.Source_flat_terminal, element_typ)
  | None ->
    (match Iteration_shape.repeated_list_element typ with
    | Some inner_list_typ ->
    Some (Helper_request.Source_nested_seq, inner_list_typ)
    | None -> None)

let is_sequence_sort sort =
  sort_name sort = "SpectecTerminals"

let lower_with_source_carrier ctx env origin exp =
  match Expr_translate.carrier_sort_of_typ exp.note with
  | Some sort when is_sequence_sort sort ->
    Expr_translate.lower_sequence ctx env origin exp
  | _ -> Expr_translate.lower_value ctx env origin exp
