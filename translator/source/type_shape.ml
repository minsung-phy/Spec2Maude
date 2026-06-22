open Il.Ast
open Util.Source

let typ_is_iter typ =
  match typ.it with
  | IterT _ -> true
  | _ -> false

let is_flat_list_typ typ =
  match typ.it with
  | IterT (element_typ, List) -> not (typ_is_iter element_typ)
  | _ -> false

let is_flat_optional_typ typ =
  match typ.it with
  | IterT (element_typ, Opt) -> not (typ_is_iter element_typ)
  | _ -> false

let is_nested_list_typ typ =
  match typ.it with
  | IterT ({ it = IterT (element_typ, List); _ }, List) ->
    not (typ_is_iter element_typ)
  | _ -> false

let is_optional_list_typ typ =
  match typ.it with
  | IterT ({ it = IterT (element_typ, Opt); _ }, List) ->
    not (typ_is_iter element_typ)
  | _ -> false

let is_list_optional_typ typ =
  match typ.it with
  | IterT ({ it = IterT (element_typ, List); _ }, Opt) ->
    not (typ_is_iter element_typ)
  | _ -> false

let typ_components typ =
  match typ.it with
  | TupT components -> components
  | VarT (id, _) ->
    let payload = VarE id $$ typ.at % typ in
    [ payload, typ ]
  | _ ->
    let wildcard = VarE ("_" $ typ.at) $$ typ.at % typ in
    [ wildcard, typ ]

let mixop_is_hole_only mixop =
  List.for_all (( = ) []) mixop
