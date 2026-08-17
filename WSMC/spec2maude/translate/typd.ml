open Util.Source
open Il.Ast
open Maude_il

let translate_components typ =
  Term.translate_components typ

let parameter_names params =
  List.filter_map
    (fun (param : param) ->
      match param.it with ExpP (id, _) -> Some id.it | _ -> None)
    params

let payload_names (typ : typ) =
  match typ.it with
  | TupT fields ->
      fields
      |> List.filter_map (fun (id, _) ->
           if id.it = "_" then None else Some id.it)
  | _ -> []

(* AliasT *)
let translate_target id params args = 
  let terms =
    match args with
    | [] -> Param.translate_terms params
    | _ -> args |> List.map Term.translate_arg
  in App (Term.source_name id, terms)

let translate_alias id params quants args typ = 
  let value = Var { name = "VALUE" ; sort = Term.translate_sort typ} in
  let target = translate_target id params args in
  let source = Term.translate_typ typ in
  let left = App ("typecheck", [value; target]) in
  let right = App ("typecheck", [value; source]) in
  let conditions = Param.translate_eq_conditions quants in
  match conditions with
  | [] -> [Eq (left, right, [])]
  | _ -> [Ceq (left, right, conditions, [])]

(* StructT *)
let join_struct_items = function
  | [] -> Const "EMPTY"
  | item :: items -> List.fold_left (fun left right -> App ("_;_", [left; right])) item items

let translate_struct_field index bound (atom, (typ, quants, prems), _hints) =
  match translate_components typ with
  | [(value, _, type_conditions)] ->
      let field = Const ("'" ^ Il.Print.string_of_atom atom) in
      let item = App ("item", [field; value]) in
      let bound = bound @ parameter_names quants @ payload_names typ in
      let conditions = type_conditions @ Param.translate_eq_conditions quants
        @ Prem.translate_eq_conditions index ~bound prems in
      (item, conditions)
  | _ -> invalid_arg "a StructT field must contain exactly one value"

let translate_struct index id params quants args fields =
  let target =
    translate_target id params args
  in

  let translated_fields =
    fields
    |> List.map
         (translate_struct_field index
            (parameter_names params @ parameter_names quants))
  in

  let record =
    translated_fields
    |> List.map fst
    |> join_struct_items
    |> fun items -> App ("{_}", [items])
  in

  let conditions =
    Param.translate_eq_conditions quants
    @
    (translated_fields
     |> List.concat_map snd)
  in

  let left =
    App ("typecheck", [record; target])
  in

  match conditions with
  | [] ->
      [Eq (left, Const "true", [])]

  | _ ->
      [Ceq
        ( left
        , Const "true"
        , conditions
        , []
        )]

(* VariantT *)
let is_hole_only mixop = Xl.Mixop.flatten mixop |> List.for_all (( = ) [])

let translate_union target case_conditions typ _hints =
  let value = Var { name = "VALUE" ; sort = Term.translate_sort typ } in
  let source = Term.translate_typ typ in
  let left = App ("typecheck", [value; target]) in
  let source_condition = BoolCond (App ("typecheck", [value; source])) in
  let conditions = case_conditions @ [source_condition] in
  [Ceq (left, Const "true", conditions, [])]

let translate_constructor _id target case_conditions mixop typ _hints =
  let constructor_name = Mixop.name mixop in
  let components = translate_components typ in
  let values = components |> List.map (fun (value, _, _) -> value) in
  let domain = components |> List.map (fun (_, sort, _) -> sort) in
  let component_conditions = components |> List.concat_map (fun (_, _, conditions) -> conditions) in
  let constructor = App (constructor_name, values) in
  let declaration = OpDecl { name = constructor_name ; domain ; codomain = "SpectecTerminal" ; 
                             arrow = if components = [] then Total else Partial ; attrs = [Ctor] } in
  let membership =
    match components with
    | [] -> []
    | _ -> [Cmb ( constructor, "SpectecTerminal", component_conditions )] in
  let typecheck_conditions = case_conditions @
    match components with
    | [] -> []
    | _ -> [MembershipCond ( constructor, "SpectecTerminal" )] in
  let left = App ("typecheck", [constructor; target]) in
  let typecheck_statement =
    match typecheck_conditions with
    | [] ->  Eq ( left, Const "true", [] )
    | _ -> Ceq ( left, Const "true", typecheck_conditions, [] ) in
  [declaration] @ membership @ [typecheck_statement]

let translate_numeric_case target case_conditions typ _quants prems _hints =
  match typ.it, prems, translate_components typ with
  | TupT [(_, payload_typ)], [{it = IfPr _; _}], [(value, _, _)] ->
      begin match payload_typ.it with
      | NumT (`NatT | `IntT) -> 
        let left = App ("typecheck", [value; target]) in
        let statement =
            Ceq ( left, Const "true", case_conditions, [] ) in
        Some [statement]
      | _ -> None
      end
  | _ -> None

let translate_typcase index id target instance_conditions bound
    (mixop, (typ, quants, prems), hints) =
  let bound = bound @ parameter_names quants @ payload_names typ in
  let case_conditions = instance_conditions @ Param.translate_eq_conditions quants
    @ Prem.translate_eq_conditions index ~bound prems
  in
  if is_hole_only mixop then
    match translate_numeric_case target case_conditions typ quants prems hints
    with
    | Some statements -> statements
    | None -> translate_union target case_conditions typ hints
  else translate_constructor id target case_conditions mixop typ hints

let translate_variant index id params quants args cases =
  let target = translate_target id params args in
  let instance_conditions = Param.translate_eq_conditions quants in
  let bound = parameter_names params @ parameter_names quants in
  cases
  |> List.concat_map (translate_typcase index id target instance_conditions bound)

(* TypD *)
let translate_type_decl id params =
  let domain = Param.translate_sorts params in
  OpDecl { name = Term.source_name id ; domain ; codomain = "SpectecType" ; arrow = Total ; attrs = [] }

let translate_deftyp index id params quants args deftyp =
  match deftyp.it with
  | AliasT typ -> translate_alias id params quants args typ
  | StructT fields -> translate_struct index id params quants args fields
  | VariantT cases -> translate_variant index id params quants args cases

let translate_inst index id params inst =
  match inst.it with
  | InstD (quants, args, deftyp) ->
      translate_deftyp index id params quants args deftyp

let translate index id params insts =
  let type_decl = translate_type_decl id params in
  let definitions = insts |> List.concat_map (translate_inst index id params) in
  type_decl :: definitions
