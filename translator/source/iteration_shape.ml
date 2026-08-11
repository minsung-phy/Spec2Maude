open Il.Ast
open Util.Source

let flat element =
  if Type_shape.typ_is_iter element then None else Some element

let flat_optional_element typ =
  match typ.it with
  | IterT (element, Opt) -> flat element
  | _ -> None

let flat_list_element typ =
  match typ.it with
  | IterT (element, List) -> flat element
  | _ -> None

let flat_repeated_element typ =
  match typ.it with
  | IterT (element, (List | List1 | ListN _)) -> flat element
  | _ -> None

let list_of_lists_element typ =
  match typ.it with
  | IterT (({ it = IterT (element, List); _ } as inner), List) ->
    Option.map (fun _ -> inner) (flat element)
  | _ -> None

let list_of_optionals_element typ =
  match typ.it with
  | IterT (({ it = IterT (element, Opt); _ } as inner), List) ->
    Option.map (fun _ -> inner) (flat element)
  | _ -> None

let optional_list_element typ =
  match typ.it with
  | IterT (({ it = IterT (element, List); _ } as inner), Opt) ->
    Option.map (fun _ -> inner) (flat element)
  | _ -> None

let repeated_list_element typ =
  match typ.it with
  | IterT
      (({ it = IterT (element, List); _ } as inner),
       (List | List1 | ListN _)) ->
    Option.map (fun _ -> inner) (flat element)
  | _ -> None

let repeated_sequence_element typ =
  match typ.it with
  | IterT
      (({ it = IterT (element, (List | Opt)); _ } as inner),
       (List | List1 | ListN _)) ->
    Option.map (fun _ -> inner) (flat element)
  | _ -> None
