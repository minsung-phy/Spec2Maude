open Il.Ast
open Maude_ir
open Util.Source

let carries_sequence ctx typ =
  match Carrier_sort.for_typd ctx typ with
  | Ok sort -> Carrier_sort.is_sequence_sort sort
  | Error _ -> false

let app name args = App (name, args)
let condition term = BoolCond term
let typecheck value witness = condition (Typecheck_term.typecheck value witness)
let is_opt value = condition (app "isOpt" [ value ])
let all_opt value = condition (app "allOpt" [ value ])
let all_seq value = condition (app "allSeq" [ value ])

let nested_typecheck value witness =
  [ all_seq value
  ; typecheck (app "flattenNested" [ value ]) witness
  ]

let for_typ ctx typ _ value witness =
  match typ.it with
  | IterT (inner, Opt) when not (Type_shape.typ_is_iter inner) ->
    [ is_opt value
    ; typecheck value witness
    ]
  | IterT ({ it = IterT (inner, Opt); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ all_opt value
    ; typecheck (app "flattenNested" [ value ]) witness
    ]
  | IterT ({ it = IterT (inner, List); _ }, Opt)
    when not (Type_shape.typ_is_iter inner) ->
    is_opt value :: nested_typecheck value witness
  | IterT ({ it = IterT (inner, List); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    nested_typecheck value witness
  | IterT (inner, List) when carries_sequence ctx inner ->
    nested_typecheck value witness
  | IterT (inner, Opt) when carries_sequence ctx inner ->
    is_opt value :: nested_typecheck value witness
  | _ -> [ typecheck value witness ]
