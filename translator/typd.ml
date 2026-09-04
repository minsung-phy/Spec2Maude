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

(* Typed-list support belongs to TypD lowering: Hintd decides which syntax
 * sorts need lists, and this private emitter materializes their Maude units. *)
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
           ; rename "nil" sequence.empty
           ; rename "append" sequence.append
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
           @ (if sequence.concat = "_ _" then []
              else [rename "__" sequence.concat])
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
    let element = var "LIST-ELEMENT" sort in
    let other = var "LIST-OTHER" sort in
    let left = var "LIST-LEFT" list in
    let rest = var "LIST-REST" list in
    let count = var "LIST-COUNT" "Nat" in
    let concat left right = app sequence.concat [left; right] in
    let append left right = app sequence.append [left; right] in
    let root = Hintd.typed_list_root metadata sort in
    let head = root ^ "Head" in
    let tail = root ^ "Tail" in
    let last = root ^ "Last" in
    let front = root ^ "Front" in
    let reverse_name = root ^ "Reverse" in
    let reverse_aux = root ^ "ReverseAux" in
    let size_aux = root ^ "SizeAux" in
    let concat_name = if sequence.concat = "_ _" then "__" else sequence.concat in
    [ SortDecl nonempty
    ; SortDecl list
    ; SubsortDecl (sort, nonempty)
    ; SubsortDecl (nonempty, list)
    ; op ~attrs:[Ctor] sequence.empty [] list
    ; op ~attrs:[Ctor; Ditto] concat_name [list; list] list
    ; op ~attrs:[Ctor; Ditto] concat_name [nonempty; list] nonempty
    ; op ~attrs:[Ctor; Ditto] concat_name [list; nonempty] nonempty
    ; op sequence.append [list; list] list
    ; op sequence.append [nonempty; list] nonempty
    ; op sequence.append [list; nonempty] nonempty
    ; eq (append (term left) (term rest)) (concat (term left) (term rest))
    ; op head [nonempty] sort
    ; eq (app head [concat (term element) (term rest)]) (term element)
    ; op tail [nonempty] list
    ; eq (app tail [concat (term element) (term rest)]) (term rest)
    ; op last [nonempty] sort
    ; eq (app last [concat (term left) (term element)]) (term element)
    ; op front [nonempty] list
    ; eq (app front [concat (term left) (term element)]) (term left)
    ; op sequence.occurs [sort; list] "Bool"
    ; eq (app sequence.occurs [term element; Const sequence.empty])
        (Const "false")
    ; eq
        ( app sequence.occurs
            [term element; concat (term other) (term rest)]
        )
        (app "if_then_else_fi"
            [ app "_==_" [term element; term other]
            ; Const "true"
            ; app sequence.occurs [term element; term rest]
            ]
        )
    ; op reverse_name [list] list
    ; op reverse_name [nonempty] nonempty
    ; eq (app reverse_name [term rest])
        (app reverse_aux [term rest; Const sequence.empty])
    ; op reverse_aux [list; list] list
    ; eq (app reverse_aux [Const sequence.empty; term left]) (term left)
    ; eq
        ( app reverse_aux
            [concat (term element) (term rest); term left]
        )
        (app reverse_aux
            [term rest; concat (term element) (term left)]
        )
    ; op sequence.size [list] "Nat"
    ; op sequence.size [nonempty] "NzNat"
    ; eq (app sequence.size [term rest])
        (app size_aux [term rest; Const "0"])
    ; op size_aux [list; "Nat"] "Nat"
    ; eq (app size_aux [Const sequence.empty; term count]) (term count)
    ; eq
        ( app size_aux [concat (term element) (term rest); term count]
        )
        (app size_aux
            [term rest; app "_+_" [term count; Const "1"]]
        )
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

  let generic_sequence =
    let element = var "SEQUENCE-ELEMENT" "SpectecTerminal" in
    let rest = var "SEQUENCE-REST" "SpectecTerminals" in
    let value = var "TYPECHECK-VALUE" "[SpectecTerminal]" in
    let typ = var "TYPECHECK-TYPE" "SpectecType" in
    let check value = app "typecheck" [value; term typ] in
    [ SortDecl "SpectecTerminals"
    ; SubsortDecl ("SpectecTerminal", "SpectecTerminals")
    ; op ~attrs:[Ctor] "eps" [] "SpectecTerminals"
    ; op
        ~attrs:[Ctor; Assoc; Id (Const "eps"); Prec 25]
        "__" ["SpectecTerminals"; "SpectecTerminals"] "SpectecTerminals"
    ; op ~attrs:[Ctor] "seq" ["SpectecTerminals"] "SpectecTerminal"
    ; op ~arrow:Partial "unseq" ["SpectecTerminal"] "SpectecTerminals"
    ; eq (app "unseq" [app "seq" [term rest]]) (term rest)
    ; eq (check (Const "eps")) (Const "true")
    ; Ceq
        ( check (app "_ _" [term element; term rest])
        , check (term rest)
        , [ BoolCond (app "_=/=_" [term rest; Const "eps"])
          ; BoolCond (check (term element))
          ]
        , [])
    ; Eq (check (term value), Const "false", [Owise])
    ]

  let statements metadata =
    let sorts = Hintd.typed_list_sorts metadata in
    let roots = Hintd.typed_list_roots metadata in
    let lower =
      sorts
      |> List.filter (fun sort -> not (List.mem sort roots))
      |> List.concat_map (lower_list metadata)
    in
    let generic_edges =
      roots
      |> List.map (fun sort -> SubsortDecl (list_sort sort, "SpectecTerminals"))
    in
    generic_sequence @ list_edges metadata @ generic_edges @ lower
    @ List.concat_map (repeat metadata) sorts

  let generated_statements metadata =
    Hintd.typed_list_sorts metadata
    |> List.concat_map (lift metadata)

end

let list_views = Lists.views
let list_imports = Lists.imports
let list_statements = Lists.statements
let list_generated_statements = Lists.generated_statements
