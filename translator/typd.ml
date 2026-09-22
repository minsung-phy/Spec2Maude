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

(* InstD arguments bind patterns in the generated type equations. *)
let translate_target index id params args =
  let step (terms, conditions, bound) (position, arg) =
    match arg.it with
    | ExpA exp ->
        begin match Prem.translate_pattern_parts index exp with
        | Some (term, guards) ->
            term :: terms, conditions @ guards, Prem.bind bound exp
        | None ->
            let subject =
              Var
                (generated_variable
                   ("TYPE-ARG" ^ string_of_int (position + 1))
                   (Term.translate_sort index exp.note))
            in
            let binding =
              Prem.bind_pattern index bound exp subject
                "type instance argument is not a structural pattern"
            in
            let guards =
              List.map
                (function
                  | EqCondition condition -> condition
                  | RewriteCond _ ->
                      invalid_arg "type instance pattern requires rewriting")
                binding.conditions
            in
            subject :: terms, conditions @ guards, binding.bound
        end
    | TypA _ | DefA _ | GramA _ ->
        Term.translate_arg index arg :: terms, conditions, bound
  in
  if args = [] then
    App (Prescan.typ_name index id, Param.translate_terms index params), [],
    target_names params args
  else
    let terms, guards, bound =
      List.mapi (fun i arg -> i, arg) args
      |> List.fold_left step ([], [], Il.Free.Set.empty)
    in
    let expected = Frontend.Det.(det_list det_arg args).varid in
    if not (Il.Free.Set.subset expected bound) then
      invalid_arg "type instance pattern does not bind every deterministic variable";
    App (Prescan.typ_name index id, List.rev terms), guards,
    Il.Free.Set.elements bound

(* AliasT *)
let translate_alias index target quants typ =
  let sort = Term.translate_sort index typ in
  let value = Var (generated_variable "VALUE" sort) in
  let source = Term.translate_typ index typ in
  let left = App ("typecheck", [value; target]) in
  let right = App ("typecheck", [value; source]) in
  let conditions = Param.translate_eq_conditions index quants in
  let direct = equation left right conditions in
  if sort = "SpectecTerminals" then
    let boxed = App ("typecheck", [App ("seq", [value]); target]) in
    [equation boxed right conditions; direct]
  else [direct]

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
        @ Param.translate_eq_conditions index quants
      in
      item, conditions
  | _ -> invalid_arg "a StructT field must contain exactly one value"

let rec composable index seen typ =
  not (List.exists (Il.Eq.eq_typ typ) seen)
  && match (Il.Eval.reduce_typdef index.Prescan.type_env typ).it with
     | AliasT {it = IterT _; _} -> true
     | StructT fields ->
         List.for_all
           (fun (_, (field_typ, _, _), _) ->
             composable index (typ :: seen) field_typ)
           fields
     | AliasT _ | VariantT _ -> false

let translate_struct_composition index target fields =
  if not (List.for_all (fun (_, (typ, _, _), _) -> composable index [] typ) fields)
  then [] else
  let left = Var (generated_variable "LEFT" "Record") in
  let right = Var (generated_variable "RIGHT" "Record") in
  let result =
    fields
    |> List.map (fun (atom, (typ, _, _), _) ->
         let field = Term.qid_of_atom atom in
         let value =
           Term.translate_composition index typ
             (App ("_._", [left; field])) (App ("_._", [right; field]))
         in
         App ("item", [field; value]))
    |> join_struct_items
    |> fun items -> App ("{_}", [items])
  in
  [equation (App ("recordConcat", [left; right; target])) result []]

let translate_struct index target bound quants fields =
  let translated_fields =
    List.map (translate_struct_field index bound) fields
  in
  let items = List.map fst translated_fields in
  let instance_conditions = Param.translate_eq_conditions index quants in
  let conditions =
    instance_conditions
    @ List.concat_map snd translated_fields
  in
  let record = App ("{_}", [join_struct_items items]) in
  let left = App ("typecheck", [record; target]) in
  [equation left (Const "true") conditions]
  @ translate_struct_composition index target fields

(* VariantT declarations provide constructors and explicit type predicates. *)
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
  [equation left (Const "true") (case_conditions @ component_conditions)]

let translate_constructor index target case_conditions mixop typ =
  let constructor_name = Prescan.mixop_name index mixop in
  let constructor_sort =
    "SpectecTerminal"
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
  [ declaration
  ; equation left (Const "true") typecheck_conditions
  ]

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

let translate_variant index target bound quants cases =
  let instance_conditions = Param.translate_eq_conditions index quants in
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

let guard_statements conditions statements =
  let guard = function
    | Eq (left, right, attrs) -> Ceq (left, right, conditions, attrs)
    | Ceq (left, right, guards, attrs) ->
        Ceq (left, right, conditions @ guards, attrs)
    | Mb (term, sort) -> Cmb (term, sort, conditions)
    | Cmb (term, sort, guards) -> Cmb (term, sort, conditions @ guards)
    | statement -> statement
  in
  if conditions = [] then statements else List.map guard statements

let translate_deftyp index target bound quants deftyp =
  match deftyp.it with
  | AliasT typ -> translate_alias index target quants typ
  | StructT fields -> translate_struct index target bound quants fields
  | VariantT cases -> translate_variant index target bound quants cases

let translate_inst index id params inst =
  match inst.it with
  | InstD (quants, args, deftyp) ->
      let target, guards, bound = translate_target index id params args in
      translate_deftyp index target bound quants deftyp
      |> guard_statements guards

let translate index id params insts =
  let definitions =
    List.concat_map (translate_inst index id params) insts
  in
  translate_type_decl index id params :: definitions
