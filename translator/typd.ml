open Util.Source
open Il.Ast
open Maude_il

let equation left right = function
  | [] -> Eq (left, right, [])
  | conditions -> Ceq (left, right, conditions, [])

let target_names params args =
  if args = [] then
    Il.Free.(bound_params params).varid |> Il.Free.Set.elements
  else
    Frontend.Det.(det_list det_arg args).varid |> Il.Free.Set.elements

let payload_names (typ : typ) =
  match typ.it with
  | TupT fields ->
      fields
      |> List.filter_map (fun (id, _) ->
           if id.it = "_" then None else Some id.it)
  | _ -> []

(* AliasT *)
let translate_target index id params args =
  let terms =
    match args with
    | [] -> Param.translate_terms index params
    | _ -> args |> List.map (Term.translate_arg index)
  in App (Prescan.typ_name index id, terms)

let translate_alias index id params quants args typ =
  let sort = Term.translate_sort index typ in
  let value = Var (generated_variable "VALUE" sort) in
  let target = translate_target index id params args in
  let source = Term.translate_typ index typ in
  let left = App ("typecheck", [value; target]) in
  let right = App ("typecheck", [value; source]) in
  let conditions = Param.translate_eq_conditions index quants in
  let direct = equation left right conditions in
  if sort = "SpectecTerminals" then
    let boxed = App ("typecheck", [App ("seq", [value]); target]) in
    [equation boxed right conditions; direct]
  else
    [direct]

(* StructT *)
let join_struct_items = function
  | [] -> Const "EMPTY"
  | item :: items ->
      List.fold_left
        (fun left right -> App ("_;_", [left; right])) item items

let translate_struct_field index bound (atom, (typ, quants, prems), _hints) =
  match Term.translate_components index typ with
  | [(value, _, type_conditions)] ->
      let field = Const ("'" ^ Il.Print.string_of_atom atom) in
      let item = App ("item", [field; value]) in
      let bound = bound @ payload_names typ in
      let conditions =
        type_conditions @ Prem.translate_eq_conditions index ~bound prems
        @ Param.translate_eq_conditions index quants in
      (item, conditions)
  | _ -> invalid_arg "a StructT field must contain exactly one value"

let translate_struct index id params quants args fields =
  let target =
    translate_target index id params args
  in

  let translated_fields =
    fields
    |> List.map
         (translate_struct_field index
            (target_names params args))
  in

  let record =
    translated_fields
    |> List.map fst
    |> join_struct_items
    |> fun items -> App ("{_}", [items])
  in

  let conditions =
    Param.translate_eq_conditions index quants
    @
    (translated_fields
     |> List.concat_map snd)
  in

  let left =
    App ("typecheck", [record; target])
  in
  [equation left (Const "true") conditions]

(* VariantT *)
let transparent_payload index typ =
  let components = Term.translate_components index typ in
  let values = List.map (fun (value, _, _) -> value) components in
  let value =
    match typ.it, values with
    | TupT [_], [value] -> value
    | TupT fields, values ->
        List.map2
          (fun (_, typ) value -> Term.as_sequence_element index typ value)
          fields values
        |> Term.sequence
        |> fun values -> App ("tuple", [values])
    | _, [value] -> value
    | _, _ -> invalid_arg "non-tuple type has multiple components"
  in
  let conditions =
    components
    |> List.concat_map (fun (_, _, conditions) -> conditions)
  in
  value, conditions

let translate_union index target case_conditions typ =
  let value, component_conditions = transparent_payload index typ in
  let left = App ("typecheck", [value; target]) in
  let conditions = case_conditions @ component_conditions in
  [equation left (Const "true") conditions]

let translate_constructor index target case_conditions mixop typ =
  let constructor_name = Prescan.mixop_name index mixop in
  let constructor_sort =
    Sort_metadata.constructor_result_sort
      (Prescan.sort_metadata index) mixop
  in
  let components = Term.translate_components index typ in
  let values = components |> List.map (fun (value, _, _) -> value) in
  let domain = components |> List.map (fun (_, sort, _) -> sort) in
  let component_conditions =
    components |> List.concat_map (fun (_, _, conditions) -> conditions)
  in
  let constructor = App (constructor_name, values) in
  let declaration =
    OpDecl
      { name = constructor_name
      ; domain
      ; codomain = constructor_sort
      ; arrow = Total
      ; attrs = [Ctor]
      }
  in
  let typecheck_conditions = case_conditions @ component_conditions in
  let left = App ("typecheck", [constructor; target]) in
  [declaration; equation left (Const "true") typecheck_conditions]

let translate_typcase index target instance_conditions bound
    (mixop, (typ, quants, prems), _hints) =
  let bound = bound @ payload_names typ in
  let case_conditions =
    Prem.translate_eq_conditions index ~bound prems
    @ Param.translate_eq_conditions index quants @ instance_conditions
  in
  if Mixop.is_hole_only mixop then
    translate_union index target case_conditions typ
  else translate_constructor index target case_conditions mixop typ

let translate_variant index id params quants args cases =
  let target = translate_target index id params args in
  let instance_conditions = Param.translate_eq_conditions index quants in
  let bound = target_names params args in
  cases
  |> List.concat_map (translate_typcase index target instance_conditions bound)

(* TypD *)
let translate_type_decl index id params =
  let domain = Param.translate_sorts index params in
  OpDecl
    { name = Prescan.typ_name index id
    ; domain
    ; codomain = "SpectecType"
    ; arrow = Total
    ; attrs = []
    }

let translate_deftyp index id params quants args deftyp =
  match deftyp.it with
  | AliasT typ -> translate_alias index id params quants args typ
  | StructT fields -> translate_struct index id params quants args fields
  | VariantT cases -> translate_variant index id params quants args cases

let translate_inst index id params inst =
  match inst.it with
  | InstD (quants, args, deftyp) ->
      translate_deftyp index id params quants args deftyp

let translate index id params insts =
  let type_decl = translate_type_decl index id params in
  let definitions = insts |> List.concat_map (translate_inst index id params) in
  type_decl :: definitions
