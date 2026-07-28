open Il.Ast
open Maude_ir
open Util.Source

let carries_sequence ctx typ =
  match Carrier_sort.for_typd ctx typ with
  | Ok sort -> Carrier_sort.is_sequence_sort sort
  | Error _ -> false

let for_typ ctx typ sort value witness =
  match typ.it with
  | IterT (inner, Opt) when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (App ("isOpt", [ value ]))
    ; BoolCond (Typecheck_term.typecheck_seq value witness)
    ]
  | IterT ({ it = IterT (inner, Opt); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (Typecheck_term.typecheck_opt_seq value witness) ]
  | IterT ({ it = IterT (inner, List); _ }, Opt)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (Typecheck_term.typecheck_seq_opt value witness) ]
  | IterT ({ it = IterT (inner, List); _ }, List)
    when not (Type_shape.typ_is_iter inner) ->
    [ BoolCond (Typecheck_term.typecheck_nested_seq value witness) ]
  | IterT (inner, List) when carries_sequence ctx inner ->
    [ BoolCond (Typecheck_term.typecheck_nested_seq value witness) ]
  | IterT (inner, Opt) when carries_sequence ctx inner ->
    [ BoolCond (Typecheck_term.typecheck_seq_opt value witness) ]
  | _ -> [ BoolCond (Typecheck_term.typecheck_for_sort sort value witness) ]
