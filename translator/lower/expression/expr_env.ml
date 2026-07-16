type binding =
  { term : Maude_ir.term
  ; sort : Maude_ir.sort
  ; typ : Il.Ast.typ
  }

type t =
  { vars : (string * binding) list
  ; condition_bound_vars : string list option
  }

let empty = { vars = []; condition_bound_vars = None }

let add env id binding =
  { env with vars = (id, binding) :: env.vars }

let find env id =
  List.assoc_opt id env.vars

let bound_vars env =
  env.vars
  |> List.concat_map (fun (_id, binding) ->
    Condition_closure.term_vars binding.term)
  |> List.sort_uniq String.compare

let condition_bound_vars env =
  env.condition_bound_vars

let with_condition_bound_vars env vars =
  { env with
    condition_bound_vars = Some (List.sort_uniq String.compare vars)
  }
