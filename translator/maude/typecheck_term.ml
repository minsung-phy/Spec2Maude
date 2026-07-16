open Maude_ir

let typecheck value typ = App ("typecheck", [ value; typ ])
let typecheck_seq value typ = App ("typecheckSeq", [ value; typ ])
let typecheck_opt_seq value typ = App ("typecheckOptSeq", [ value; typ ])
let typecheck_seq_opt value typ = App ("typecheckSeqOpt", [ value; typ ])
let typecheck_nested_seq value typ = App ("typecheckNestedSeq", [ value; typ ])

let typecheck_for_sort sort value typ =
  if sort_name sort = "SpectecTerminals" then
    typecheck_seq value typ
  else
    typecheck value typ
