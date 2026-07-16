open Maude_ir

let spectec_terminal = sort "SpectecTerminal"
let spectec_terminals = sort "SpectecTerminals"
let spectec_type = sort "SpectecType"
let nat = sort "Nat"

let app name args =
  App (name, args)

let concat left right =
  app "_ _" [ left; right ]

let generated name origin node =
  Maude_ir.generated ~provenance:(Helper name) ~origin node

let variable_declarations statement variables =
  variables
  |> List.filter_map (fun (name, type_ref) ->
    if String.contains name ':' then None
    else Some (statement (var name type_ref)))

let succ term =
  app "s_" [ term ]

let not_eps tail_var =
  BoolCond (app "_=/=_" [ Var tail_var; Const "eps" ])
