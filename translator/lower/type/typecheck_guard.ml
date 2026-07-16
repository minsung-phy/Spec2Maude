open Il.Ast
open Maude_ir
open Util.Source

let for_typ typ sort value witness =
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
  | _ -> [ BoolCond (Typecheck_term.typecheck_for_sort sort value witness) ]
