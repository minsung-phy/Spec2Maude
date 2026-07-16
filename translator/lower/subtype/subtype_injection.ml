type case =
  { source_op : string
  ; target_op : string
  ; payload_sorts : Maude_ir.sort list
  }

type t =
  { source_category : string
  ; target_category : string
  ; cases : case list
  }

let make_case ~source_op ~target_op ~payload_sorts =
  { source_op; target_op; payload_sorts }

let make ~source_category ~target_category ~cases =
  { source_category; target_category; cases }

let source_category injection = injection.source_category
let target_category injection = injection.target_category
let cases injection = injection.cases
let source_op case = case.source_op
let target_op case = case.target_op
let payload_sorts case = case.payload_sorts

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
    [ case.source_op
    ; case.target_op
    ; String.concat "," (List.map Maude_ir.sort_name case.payload_sorts)
    ]

let key injection =
  String.concat
    "\000"
    [ injection.source_category
    ; injection.target_category
    ; String.concat "\001"
        (injection.cases |> List.map case_key |> List.sort String.compare)
    ]
