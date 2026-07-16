open Il.Ast
open Util.Source

type source =
  { component_index : int
  ; source_exp : exp
  ; element_typ : typ option
  }

let source_preserving_iter exp =
  match exp.it with
  | IterE ({ it = VarE body; _ }, (List, [ generator, source ]))
    when String.equal body.it generator.it ->
    source
  | _ -> exp

let flat_list_element typ =
  match typ.it with
  | IterT (element, (List | List1 | ListN _))
    when not (Type_shape.typ_is_iter element) ->
    Some element
  | _ -> None

let rec indexed_source exp =
  match exp.it with
  | SubE (inner, source_typ, _) ->
    (match indexed_source inner with
    | Some (source, None) -> Some (source, Some source_typ)
    | indexed -> indexed)
  | CvtE (inner, _, _) -> indexed_source inner
  | IdxE (source, { it = VarE _; _ }) -> Some (source, None)
  | IdxE _ | VarE _ | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _
  | CmpE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | ListE _
  | TupE _ | StrE _ | DotE _ | CompE _ | LenE _ | CatE _ | MemE _
  | SliceE _ | UpdE _ | ExtE _ | CallE _ | IterE _ | LiftE _ | IfE _ ->
    None

let single_source components =
  let indexed =
    components
    |> List.mapi (fun component_index component ->
      match indexed_source component with
      | None -> None
      | Some (source_exp, element_typ) ->
        let source_exp = source_preserving_iter source_exp in
        let element_typ =
          match element_typ with
          | Some _ -> element_typ
          | None -> flat_list_element source_exp.note
        in
        Some { component_index; source_exp; element_typ })
    |> List.filter_map Fun.id
  in
  match indexed with
  | [ source ] -> Some source
  | [] | _ :: _ :: _ -> None
