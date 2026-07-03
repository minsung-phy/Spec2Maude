open Il.Ast
open Maude_ir
open Util.Source

let with_conditions env bound_vars conditions diagnostics =
  { (Premise_result.empty_with_env
       ~bound_vars:(Condition_closure.conditions_bound_vars bound_vars conditions)
       env)
    with
    eq_conditions = conditions
  ; diagnostics
  }

let take_match_binding var conditions =
  let rec loop acc = function
    | [] -> None
    | MatchCond (Var actual, term) :: rest when actual = var ->
      Some (term, List.rev_append acc rest)
    | condition :: rest -> loop (condition :: acc) rest
  in
  loop [] conditions

let target_id ids id =
  match ids with
  | None -> true
  | Some ids -> List.exists (( = ) id) ids

let add_introduced_bindings ?ids env bindings =
  bindings
  |> List.fold_left
       (fun env (id, binding) ->
         if target_id ids id then
           Expr_translate.add_var env id binding
         else
           env)
       env

let binding_is_bound bound_vars (binding : Expr_translate.binding) =
  Condition_closure.term_vars binding.term
  |> List.for_all (fun var -> List.mem var bound_vars)

let source_id_is_bound env bound_vars id =
  match Expr_translate.find_var env id with
  | None -> false
  | Some binding -> binding_is_bound bound_vars binding

let unbound_direct_var env ~bound_vars exp =
  match exp.it with
  | VarE id ->
    (match Expr_translate.find_var env id.it with
    | None -> Some id
    | Some binding when not (binding_is_bound bound_vars binding) -> Some id
    | Some _ -> None)
  | _ -> None

let unbound_env_var_binding env ~bound_vars exp =
  match exp.it with
  | VarE id ->
    (match Expr_translate.find_var env id.it with
    | Some binding when not (binding_is_bound bound_vars binding) ->
      Some (id.it, binding)
    | Some _ | None -> None)
  | _ -> None

let typed_var_for_exp id exp =
  match Expr_translate.carrier_sort_of_typ exp.note with
  | None -> None
  | Some sort ->
    let term = Var (Naming.maude_var id.it ^ ":" ^ sort_name sort) in
    Some (term, { Expr_translate.term; sort; typ = exp.note })

let same_sort left right =
  sort_name left = sort_name right

let unbound_var_binding env ~bound_vars exp =
  match exp.it with
  | VarE id ->
    let typed_binding =
      typed_var_for_exp id exp |> Option.map snd
    in
    (match Expr_translate.find_var env id.it with
    | Some binding when not (binding_is_bound bound_vars binding) ->
      (match typed_binding with
      | Some typed when not (same_sort typed.Expr_translate.sort binding.sort) ->
        Some (id.it, typed)
      | Some _ | None -> Some (id.it, binding))
    | Some _ -> None
    | None ->
      (match typed_binding with
      | Some binding -> Some (id.it, binding)
      | None -> None))
  | _ -> None
