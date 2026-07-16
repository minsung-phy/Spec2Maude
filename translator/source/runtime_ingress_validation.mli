type discharge =
  { declarations : string list
  }

type t

val of_source_index : Analysis.Source_index.t -> t

val find :
  t ->
  category_id:string ->
  Il.Ast.prem ->
  discharge option
