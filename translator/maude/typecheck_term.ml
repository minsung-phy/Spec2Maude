open Maude_ir

let typecheck value typ = App ("typecheck", [ value; typ ])
let typecheck_opt_seq value typ = App ("typecheckOptSeq", [ value; typ ])
let typecheck_seq_opt value typ = App ("typecheckSeqOpt", [ value; typ ])
let typecheck_nested_seq value typ = App ("typecheckNestedSeq", [ value; typ ])

let subject = function
  | App
      ( ( "typecheck"
        | "typecheckOptSeq"
        | "typecheckSeqOpt"
        | "typecheckNestedSeq" )
      , [ value; _ ] ) ->
    Some value
  | _ -> None

let is_typecheck term = Option.is_some (subject term)
