open Maude_ir

let rec ingress_facts ctx = function
  | App (constructor_op, args) ->
    let nested = List.concat_map (ingress_facts ctx) args in
    (match
       Typcase_constructor.ingress_certificate
         ctx ~constructor_op ~arity:(List.length args)
     with
    | Some certificate ->
      (* Matching a partial constructor at its result sort establishes the
         exact payload premises of that constructor's [cmb]. *)
      Typcase_constructor.ingress_payload_guards ctx certificate args @ nested
    | None -> nested)
  | Var _ | Const _ | Qid _ -> []

let primitive_witness sort =
  match sort_name sort with
  | "Nat" -> Some "nat"
  | "Int" -> Some "int"
  | "Rat" -> Some "rat"
  | _ -> None

let carrier_fact ctx (binding : Expr_env.binding) =
  match Carrier_sort.raw_numeric_sort_of_typ ctx binding.typ with
  | Some sort when sort = binding.sort ->
    primitive_witness sort
    |> Option.map (fun witness ->
         (* The source alias and the Maude carrier normalize to the same
            primitive numeric sort, whose prelude typecheck is total. *)
         BoolCond
           (Typecheck_term.typecheck
              binding.term
              (Const (Naming.primitive_witness witness))))
  | Some _ | None -> None

let projection_pairs ctx =
  Helper.subtype_injections (Context.helpers ctx)
  |> List.map (fun (forward, _injection) ->
       Subtype_injection.projection_name ~forward, forward)

let projection_substitution projections condition =
  let from_equality source projected =
    match projected with
    | App (project, [ target ]) ->
      List.assoc_opt project projections
      |> Option.map (fun forward -> target, App (forward, [ source ]))
    | Var _ | Const _ | Qid _ | App _ -> None
  in
  match condition with
  | MatchCond (source, projected) -> from_equality source projected
  | EqCond (left, right) ->
    (match from_equality left right with
    | Some _ as substitution -> substitution
    | None -> from_equality right left)
  | BoolCond _ | MembershipCond _ -> None

let rec normalize_term substitutions seen term =
  let term =
    match term with
    | App (op, args) ->
      App (op, List.map (normalize_term substitutions seen) args)
    | Var _ | Const _ | Qid _ -> term
  in
  if List.mem term seen then term
  else
    match List.assoc_opt term substitutions with
    | Some replacement ->
      normalize_term substitutions (term :: seen) replacement
    | None -> term

let normalize_condition substitutions = function
  | EqCond (left, right) ->
    EqCond
      (normalize_term substitutions [] left,
       normalize_term substitutions [] right)
  | MatchCond (left, right) ->
    MatchCond
      (normalize_term substitutions [] left,
       normalize_term substitutions [] right)
  | MembershipCond (term, sort) ->
    MembershipCond (normalize_term substitutions [] term, sort)
  | BoolCond term -> BoolCond (normalize_term substitutions [] term)

let condition_known substitutions condition facts =
  let condition = normalize_condition substitutions condition in
  List.exists
    (fun fact -> normalize_condition substitutions fact = condition)
    facts

let discharge ctx env ~lhs_terms conditions =
  let facts =
    List.concat_map (ingress_facts ctx) lhs_terms
    @ List.filter_map (carrier_fact ctx) (Expr_env.bindings env)
  in
  let projections = projection_pairs ctx in
  let rec loop substitutions established retained = function
    | [] -> List.rev retained
    | EqCondition condition as rule_condition :: rest ->
      let substitution = projection_substitution projections condition in
      let substitutions =
        match substitution with
        | Some substitution -> substitution :: substitutions
        | None -> substitutions
      in
      let certified =
        match condition with
        | BoolCond term when Typecheck_term.is_typecheck term ->
          condition_known substitutions condition facts
          || condition_known substitutions condition established
        | EqCond _ | MatchCond _ | MembershipCond _ | BoolCond _ -> false
      in
      let established =
        normalize_condition substitutions condition :: established
      in
      if certified then loop substitutions established retained rest
      else loop substitutions established (rule_condition :: retained) rest
    | RewriteCond _ as condition :: rest ->
      loop substitutions established (condition :: retained) rest
  in
  loop [] [] [] conditions

let discharge_eq ctx env ~lhs_terms conditions =
  conditions
  |> List.map (fun condition -> EqCondition condition)
  |> discharge ctx env ~lhs_terms
  |> List.filter_map (function
       | EqCondition condition -> Some condition
       | RewriteCond _ -> None)
