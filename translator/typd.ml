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
  match Hintd.sequence_element_wrappers (Prescan.sort_metadata index) typ with
  | None -> [direct]
  | Some (box, _) ->
      let boxed = App ("typecheck", [App (box, [value]); target]) in
      [equation boxed right conditions; direct]

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
    Hintd.constructor_result_sort
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

(* Typed-list support belongs to TypD lowering; its representations are selected
 * by the source's maude_sort hints. *)
module Lists = struct
  let title sort = String.capitalize_ascii sort
  let list_sort sort = title sort ^ "List"
  let nonempty_sort sort = "Ne" ^ list_sort sort
  let view_name sort = String.uppercase_ascii sort ^ "-VIEW"

  let module_name name = ModuleName name

  let view sort =
    View
      { name = view_name sort
      ; source = module_name "TRIV"
      ; target = module_name "SPEC2MAUDE-SORTS"
      ; mappings = [SortMapping ("Elt", sort)]
      }

  let views metadata =
    Hintd.typed_list_roots metadata |> List.map view

  let import metadata sort =
    let sequence = Hintd.typed_sequence_representation metadata sort in
    let rename source target = OpRenaming (source, target) in
    Protecting
      (ModuleRenaming
         ( ModuleInstantiation ("LIST", [view_name sort])
         , [ SortRenaming
               ("List{" ^ view_name sort ^ "}", list_sort sort)
           ; SortRenaming
               ("NeList{" ^ view_name sort ^ "}", nonempty_sort sort)
           ; TypedOpRenaming ("_xor_", ["Nat"; "Nat"], "Nat", "integerXor")
           ; rename "nil" sequence.empty
           ; rename "append" (sort ^ "Append")
           ; rename "head" (sort ^ "Head")
           ; rename "tail" (sort ^ "Tail")
           ; rename "last" (sort ^ "Last")
           ; rename "front" (sort ^ "Front")
           ; rename "occurs" sequence.occurs
           ; rename "reverse" (sort ^ "Reverse")
           ; rename "$reverse" (sort ^ "ReverseAux")
           ; rename "size" sequence.size
           ; rename "$size" (sort ^ "SizeAux")
           ]
         ))

  let imports metadata =
    Hintd.typed_list_roots metadata |> List.map (import metadata)

  let op ?(arrow = Total) ?(attrs = []) name domain codomain =
    OpDecl {name; domain; codomain; arrow; attrs}

  let app name args = App (name, args)
  let eq left right = Eq (left, right, [])
  let var name sort = generated_variable name sort
  let term variable = Var variable

  let list_edges metadata =
    let lists = Hintd.typed_list_sorts metadata in
    Hintd.subsort_edges metadata
    |> List.filter (fun (source, target) ->
         List.mem source lists && List.mem target lists)
    |> List.concat_map (fun (source, target) ->
         [ SubsortDecl (nonempty_sort source, nonempty_sort target)
         ; SubsortDecl (list_sort source, list_sort target)
         ])

  let lower_list metadata sort =
    let sequence = Hintd.typed_sequence_representation metadata sort in
    let list = sequence.sort in
    let nonempty = nonempty_sort sort in
    let root = Hintd.typed_list_root metadata sort in
    (* Preserve narrower result sorts; native equations apply to the overloads. *)
    [ SortDecl nonempty
    ; SortDecl list
    ; SubsortDecl (sort, nonempty)
    ; SubsortDecl (nonempty, list)
    ; op ~attrs:[Ctor] sequence.empty [] list
    ; op ~attrs:[Ctor; Ditto] "__" [list; list] list
    ; op ~attrs:[Ctor; Ditto] "__" [nonempty; list] nonempty
    ; op ~attrs:[Ctor; Ditto] "__" [list; nonempty] nonempty
    ; op (root ^ "Append") [list; list] list
    ; op (root ^ "Append") [nonempty; list] nonempty
    ; op (root ^ "Append") [list; nonempty] nonempty
    ; op (root ^ "Head") [nonempty] sort
    ; op (root ^ "Tail") [nonempty] list
    ; op (root ^ "Last") [nonempty] sort
    ; op (root ^ "Front") [nonempty] list
    ; op (root ^ "Reverse") [list] list
    ; op (root ^ "Reverse") [nonempty] nonempty
    ; op (root ^ "ReverseAux") [list; list] list
    ]

  let repeat metadata sort =
    let sequence = Hintd.typed_sequence_representation metadata sort in
    let count = var "REPEAT-COUNT" "Nat" in
    let element = var "REPEAT-ELEMENT" sort in
    let call count = app sequence.repeat [count; term element] in
    [ op sequence.repeat ["Nat"; sort] sequence.sort
    ; eq (call (Const "0")) (Const sequence.empty)
    ; eq (call (app "s" [term count]))
        (app sequence.concat [term element; call (term count)])
    ]

  let lift metadata sort =
    let sequence = Hintd.typed_sequence_representation metadata sort in
    let element = var "LIFT-ELEMENT" sort in
    [ op ~arrow:Partial sequence.lift ["SpectecTerminals"] sequence.sort
    ; eq (app sequence.lift [Const "eps"]) (Const sequence.empty)
    ; eq (app sequence.lift [app "_?" [term element]]) (term element)
    ]

  let statements metadata =
    let sorts = Hintd.typed_list_sorts metadata in
    let roots = Hintd.typed_list_roots metadata in
    let lower =
      sorts
      |> List.filter (fun sort -> not (List.mem sort roots))
      |> List.concat_map (lower_list metadata)
    in
    list_edges metadata @ lower
    @ List.concat_map (repeat metadata) sorts

  let generic_edges metadata =
    Hintd.typed_list_roots metadata
    |> List.map (fun sort -> SubsortDecl (list_sort sort, "SpectecTerminals"))

  let generated_statements metadata =
    Hintd.typed_list_sorts metadata
    |> List.concat_map (lift metadata)

end

let list_views = Lists.views
let list_imports = Lists.imports
let list_subsorts = Lists.generic_edges
let list_statements = Lists.statements
let list_generated_statements = Lists.generated_statements
