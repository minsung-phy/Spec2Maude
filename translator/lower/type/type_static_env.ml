type static_exp_binding =
  { static_term : Maude_ir.term
  ; static_sort : Maude_ir.sort
  ; static_typ : Il.Ast.typ
  }

type static_env =
  { exp_vars : (string * static_exp_binding) list
  ; typ_vars : (string * Maude_ir.term) list
  }

let empty = { exp_vars = []; typ_vars = [] }

let find_exp env id =
  List.assoc_opt id env.exp_vars

let find_typ env id =
  List.assoc_opt id env.typ_vars

let add_exp env id binding =
  { env with exp_vars = (id, binding) :: env.exp_vars }

let add_typ env id term =
  { env with typ_vars = (id, term) :: env.typ_vars }

let reserve_static_env names env =
  let variables =
    List.concat_map
      (fun (_, binding) -> Condition_closure.term_vars binding.static_term)
      env.exp_vars
    @ List.concat_map
        (fun (_, term) -> Condition_closure.term_vars term)
        env.typ_vars
    |> List.sort_uniq String.compare
  in
  Local_name.reserve_existing_many names variables

let to_expr_env env =
  List.fold_left
    (fun expr_env (id, binding) ->
      Expr_env.add expr_env id
        { Expr_env.term = binding.static_term
        ; sort = binding.static_sort
        ; typ = binding.static_typ
        })
    Expr_env.empty env.exp_vars
