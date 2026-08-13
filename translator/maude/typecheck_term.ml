open Maude_ir

let typecheck value typ = App ("typecheck", [ value; typ ])

let subject = function
  | App ("typecheck", [ App ("flattenNested", [ value ]); _ ])
  | App ("typecheck", [ value; _ ]) ->
    Some value
  | _ -> None

let is_typecheck term = Option.is_some (subject term)
