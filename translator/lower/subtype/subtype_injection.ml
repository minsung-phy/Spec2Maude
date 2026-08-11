type case =
  { source_mixop : Il.Ast.mixop
  ; source_op : string
  ; target_op : string
  ; payload_sorts : Maude_ir.sort list
  ; projects_totally : bool
  }

type t =
  { source_category : string
  ; target_category : string
  ; cases : case list
  }

let make_case
    ~source_mixop ~source_op ~target_op ~payload_sorts ~projects_totally =
  { source_mixop; source_op; target_op; payload_sorts; projects_totally }

let make ~source_category ~target_category ~cases =
  { source_category; target_category; cases }

let source_category injection = injection.source_category
let target_category injection = injection.target_category
let cases injection = injection.cases
let source_mixop case = case.source_mixop
let source_op case = case.source_op
let target_op case = case.target_op
let payload_sorts case = case.payload_sorts
let projects_totally case = case.projects_totally

let forward_name injection =
  "coerce-" ^ Naming.source_slug ~lower:true injection.target_category
  ^ "-from-" ^ Naming.source_slug ~lower:true injection.source_category

let projection_name ~forward =
  Naming.helper_companion ~role:"subtype-project" forward

let sequence_projection_name ~forward =
  Naming.helper_companion ~role:"subtype-project-seq" forward

let case_key case =
  String.concat
    "\000"
    [ Il.Print.string_of_mixop case.source_mixop
    ; case.source_op
    ; case.target_op
    ; String.concat "," (List.map Maude_ir.sort_name case.payload_sorts)
    ; string_of_bool case.projects_totally
    ]

let key injection =
  String.concat
    "\000"
    [ injection.source_category
    ; injection.target_category
    ; String.concat "\001"
        (injection.cases |> List.map case_key |> List.sort String.compare)
    ]
