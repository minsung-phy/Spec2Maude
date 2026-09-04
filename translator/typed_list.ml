open Maude_il

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
  Sort_metadata.typed_list_roots metadata |> List.map view

let import metadata sort =
  let sequence = Sort_metadata.typed_sequence_representation metadata sort in
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
       ))

let imports metadata =
  match Sort_metadata.typed_list_roots metadata with
  | [] -> []
  | [sort] -> [import metadata sort]
  | _ -> invalid_arg "typed-list sorts must have one common maximal sort"

let op ?(arrow = Total) ?(attrs = []) name domain codomain =
  OpDecl {name; domain; codomain; arrow; attrs}

let app name args = App (name, args)
let var name sort = generated_variable name sort
let term variable = Var variable

let list_edges metadata =
  let lists = Sort_metadata.typed_list_sorts metadata in
  Sort_metadata.subsort_edges metadata
  |> List.filter (fun (source, target) ->
       List.mem source lists && List.mem target lists)
  |> List.concat_map (fun (source, target) ->
       [ SubsortDecl (nonempty_sort source, nonempty_sort target)
       ; SubsortDecl (list_sort source, list_sort target)
       ])

let lower_list metadata sort =
  let sequence = Sort_metadata.typed_sequence_representation metadata sort in
  let list = sequence.sort in
  let nonempty = nonempty_sort sort in
  let element = var "LIST-ELEMENT" sort in
  let other = var "LIST-OTHER" sort in
  let left = var "LIST-LEFT" list in
  let rest = var "LIST-REST" list in
  let count = var "LIST-COUNT" "Nat" in
  let concat left right = app sequence.concat [left; right] in
  let append left right = app sequence.append [left; right] in
  let root = Sort_metadata.typed_list_root metadata sort in
  let head = root ^ "Head" in
  let tail = root ^ "Tail" in
  let last = root ^ "Last" in
  let front = root ^ "Front" in
  let reverse_name = root ^ "Reverse" in
  let reverse_aux = root ^ "ReverseAux" in
  let size_aux = root ^ "SizeAux" in
  [ SortDecl nonempty
  ; SortDecl list
  ; SubsortDecl (sort, nonempty)
  ; SubsortDecl (nonempty, list)
  ; op ~attrs:[Ctor] sequence.empty [] list
  ; op ~attrs:[Ctor; Ditto] "__" [list; list] list
  ; op ~attrs:[Ctor; Ditto] "__" [nonempty; list] nonempty
  ; op ~attrs:[Ctor; Ditto] "__" [list; nonempty] nonempty
  ; op sequence.append [list; list] list
  ; op sequence.append [nonempty; list] nonempty
  ; op sequence.append [list; nonempty] nonempty
  ; Eq
      (append (term left) (term rest), concat (term left) (term rest), [])
  ; op head [nonempty] sort
  ; Eq (app head [concat (term element) (term rest)], term element, [])
  ; op tail [nonempty] list
  ; Eq (app tail [concat (term element) (term rest)], term rest, [])
  ; op last [nonempty] sort
  ; Eq (app last [concat (term left) (term element)], term element, [])
  ; op front [nonempty] list
  ; Eq (app front [concat (term left) (term element)], term left, [])
  ; op sequence.occurs [sort; list] "Bool"
  ; Eq
      ( app sequence.occurs [term element; Const sequence.empty]
      , Const "false", [])
  ; Eq
      ( app sequence.occurs
          [term element; concat (term other) (term rest)]
      , app "if_then_else_fi"
          [ app "_==_" [term element; term other]
          ; Const "true"
          ; app sequence.occurs [term element; term rest]
          ]
      , [])
  ; op reverse_name [list] list
  ; op reverse_name [nonempty] nonempty
  ; Eq
      ( app reverse_name [term rest]
      , app reverse_aux [term rest; Const sequence.empty]
      , [])
  ; op reverse_aux [list; list] list
  ; Eq
      ( app reverse_aux [Const sequence.empty; term left]
      , term left, [])
  ; Eq
      ( app reverse_aux
          [concat (term element) (term rest); term left]
      , app reverse_aux
          [term rest; concat (term element) (term left)]
      , [])
  ; op sequence.size [list] "Nat"
  ; op sequence.size [nonempty] "NzNat"
  ; Eq
      ( app sequence.size [term rest]
      , app size_aux [term rest; Const "0"]
      , [])
  ; op size_aux [list; "Nat"] "Nat"
  ; Eq
      ( app size_aux [Const sequence.empty; term count]
      , term count, [])
  ; Eq
      ( app size_aux [concat (term element) (term rest); term count]
      , app size_aux
          [term rest; app "_+_" [term count; Const "1"]]
      , [])
  ]

let repeat metadata sort =
  let sequence = Sort_metadata.typed_sequence_representation metadata sort in
  let count = var "REPEAT-COUNT" "Nat" in
  let element = var "REPEAT-ELEMENT" sort in
  let call count = app sequence.repeat [count; term element] in
  [ op sequence.repeat ["Nat"; sort] sequence.sort
  ; Eq (call (Const "0"), Const sequence.empty, [])
  ; Eq
      ( call (app "s" [term count])
      , app sequence.concat [term element; call (term count)]
      , [])
  ]

let lift metadata sort =
  let sequence = Sort_metadata.typed_sequence_representation metadata sort in
  let element = var "LIFT-ELEMENT" sort in
  [ op ~arrow:Partial sequence.lift ["SpectecTerminals"] sequence.sort
  ; Eq (app sequence.lift [Const "eps"], Const sequence.empty, [])
  ; Eq
      ( app sequence.lift [app "_?" [term element]]
      , term element, [])
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
  ; Eq (app "unseq" [app "seq" [term rest]], term rest, [])
  ; Eq (check (Const "eps"), Const "true", [])
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
  let sorts = Sort_metadata.typed_list_sorts metadata in
  let roots = Sort_metadata.typed_list_roots metadata in
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
  Sort_metadata.typed_list_sorts metadata
  |> List.concat_map (lift metadata)
