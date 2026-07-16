open Il.Ast
open Util.Source
type param_kind =
  | Runtime_exp
  | Static_typ
  | Static_def
  | Static_gram

type definition =
  { id : string
  ; origin : Origin.t
  ; params : param_kind list
  ; result : typ
  ; clause_count : int
  ; partial : bool
  }

type definition_identity =
  { def_id : string
  ; specialization_key : string list
  }

type emitted_definition =
  { identity : definition_identity
  ; source_id : string
  ; op_name : string
  ; result : typ
  ; rewrite_backed : bool
  }

type inverse_status =
  | No_inverse
  | Valid_inverse of string
  | Invalid_inverse of
      { reason : string
      ; hint_origin : Origin.t
      }

type static_typ_binding =
  { param_id : string
  ; typ : typ
  ; key : string
  }

type static_def_binding =
  { param_id : string
  ; target_id : string
  ; key : string
  }

type specialization =
  { def_id : string
  ; key_components : string list
  ; static_typs : static_typ_binding list
  ; static_defs : static_def_binding list
  ; origin : Origin.t
  }

type violation =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; suggestion : string option
  ; source_echo : string option
  }

type call_resolution =
  | Plain_call
  | Specialized_call of specialization
  | Unsupported_call of string
  | Prelude_gap_call of string

type def_body =
  { body_id : id
  ; body_origin : Origin.t
  ; body_params : param list
  ; body_clauses : clause list
  }

type t =
  { definitions : definition list
  ; definitions_by_id : (string, definition) Hashtbl.t
  ; bodies_by_id : (string, def_body) Hashtbl.t
  ; definition_identity_edges : (string, definition_identity list) Hashtbl.t
  ; rewrite_backed_identities : (string, unit) Hashtbl.t
  ; specializations_by_id : (string, specialization list) Hashtbl.t
  ; inverse_statuses_by_id : (string, inverse_status) Hashtbl.t
  ; relation_analysis : Relation_analysis.t
  ; mutable violations : violation list
  }

let finite_specialization_cap = 10000

let param_kind param =
  match param.it with
  | ExpP _ -> Runtime_exp
  | TypP _ -> Static_typ
  | DefP _ -> Static_def
  | GramP _ -> Static_gram

let add_once table key value =
  if not (Hashtbl.mem table key) then Hashtbl.add table key value

let body_has_unsupported_static_param params =
  List.exists
    (fun param ->
      match param.it with
      | GramP _ -> true
      | ExpP _ | TypP _ | DefP _ -> false)
    params

let definition_body_has_static_params params =
  List.exists
    (fun param ->
      match param.it with
      | DefP _ -> true
      | ExpP _ | TypP _ | GramP _ -> false)
    params

let specialization_key specialization =
  specialization.def_id ^ "|" ^ String.concat "|" specialization.key_components

let identity_key (identity : definition_identity) =
  identity.def_id ^ "|" ^ String.concat "|" identity.specialization_key

let plain_identity def_id =
  { def_id; specialization_key = [] }

let identity_of_specialization specialization =
  { def_id = specialization.def_id
  ; specialization_key = specialization.key_components
  }

let specializations_for t id =
  match Hashtbl.find_opt t.specializations_by_id id with
  | None -> []
  | Some specializations -> specializations

let has_specialization t specialization =
  specializations_for t specialization.def_id
  |> List.exists (fun existing ->
    specialization_key existing = specialization_key specialization)

let def_signature_key params result =
  "params("
  ^ String.concat "," (List.map Il.Print.string_of_param params)
  ^ ")->"
  ^ Il.Print.string_of_typ result

let static_def_key t ~formal_id ~formal_params ~formal_result ~target_id =
  match
    Hashtbl.find_opt t.bodies_by_id target_id,
    Hashtbl.find_opt t.definitions_by_id target_id
  with
  | Some body, Some definition ->
    let formal_sig = def_signature_key formal_params formal_result in
    let actual_sig = def_signature_key body.body_params definition.result in
    if formal_sig = actual_sig then
      Ok
        ("def:" ^ formal_id ^ "->" ^ target_id
         ^ ":formal:" ^ formal_sig
         ^ ":actual:" ^ actual_sig)
    else
      Error
        ("DefA target `" ^ target_id
         ^ "` has signature `" ^ actual_sig
         ^ "`, but static DefP parameter `" ^ formal_id
         ^ "` requires `" ^ formal_sig ^ "`")
  | _ ->
    Error
      ("DefA target `" ^ target_id
       ^ "` is not a known DecD, so the static definition specialization cannot be trusted")

let call_target_id static_def_env id =
  match List.assoc_opt id.it static_def_env with
  | Some target_id -> target_id
  | None -> id.it

let resolve_call t ~static_typ_env:_static_typ_env ~static_def_env ~origin id args =
  let target_id = call_target_id static_def_env id in
  match Hashtbl.find_opt t.bodies_by_id target_id with
  | None ->
    if
      List.mem_assoc id.it static_def_env
      ||
      List.exists
        (fun arg ->
          match arg.it with
          | TypA _ | DefA _ | GramA _ -> true
          | ExpA _ -> false)
        args
    then
      Unsupported_call
        ("static definition call target `" ^ target_id ^ "` is not a known DecD")
    else if
      List.exists
        (fun arg ->
          match arg.it with
          | ExpA _ -> true
          | TypA _ | DefA _ | GramA _ -> false)
        args
    then
      Prelude_gap_call
        ("runtime CallE target `" ^ target_id
         ^ "` is not a generated DecD and has no explicit prelude/builtin handler")
    else
      Prelude_gap_call
        ("nullary CallE target `" ^ target_id
         ^ "` is not a generated DecD and has no explicit prelude/builtin handler")
  | Some body ->
    if List.length body.body_params <> List.length args then
      Unsupported_call
        (Printf.sprintf
           "CallE arity mismatch for `%s`: expected %d source argument(s), got %d"
           target_id
           (List.length body.body_params)
           (List.length args))
    else if body_has_unsupported_static_param body.body_params then
      Unsupported_call "GramP static parameters are outside the finite TypP/DefP monomorphization slice"
    else if not (definition_body_has_static_params body.body_params) then
      Plain_call
    else
      let def_bindings_rev, keys_rev, error =
        List.fold_left2
          (fun (def_bindings, keys, error) param arg ->
            match error with
            | Some _ -> def_bindings, keys, error
            | None ->
              (match param.it, arg.it with
              | TypP _, TypA _ ->
                def_bindings, keys, None
              | TypP _, (ExpA _ | DefA _ | GramA _) ->
                def_bindings, keys, Some "TypP parameter position requires a TypA argument"
              | DefP (param_id, formal_params, formal_result), DefA actual_id ->
                (match
                   static_def_key
                     t
                     ~formal_id:param_id.it
                     ~formal_params
                     ~formal_result
                     ~target_id:actual_id.it
                 with
                | Ok key ->
                  let binding =
                    { param_id = param_id.it; target_id = actual_id.it; key }
                  in
                  binding :: def_bindings, key :: keys, None
                | Error reason -> def_bindings, keys, Some reason)
              | DefP _, (ExpA _ | TypA _ | GramA _) ->
                def_bindings, keys, Some "DefP parameter position requires a DefA argument"
              | ExpP _, ExpA _ -> def_bindings, keys, None
              | ExpP _, (TypA _ | DefA _ | GramA _) ->
                def_bindings, keys, Some "runtime ExpP parameter position received a static argument"
              | GramP _, _ ->
                def_bindings,
                keys,
                Some "GramP static parameters are outside the finite TypP/DefP monomorphization slice"))
          ([], [], None)
          body.body_params
          args
      in
      (match error with
      | Some reason -> Unsupported_call reason
      | None ->
        let static_defs = List.rev def_bindings_rev in
        let key_components = List.rev keys_rev in
        Specialized_call
          { def_id = target_id
          ; key_components
          ; static_typs = []
          ; static_defs
          ; origin
          })

let rec collect_exp_calls t static_typ_env static_def_env origin acc exp =
  let acc =
    match exp.it with
    | CallE (id, args) ->
      (match
         resolve_call t ~static_typ_env ~static_def_env ~origin id args
       with
      | Specialized_call specialization -> specialization :: acc
      | Plain_call | Unsupported_call _ | Prelude_gap_call _ -> acc)
    | _ -> acc
  in
  match exp.it with
  | VarE _ | BoolE _ | NumE _ | TextE _ -> acc
  | UnE (_, _, exp1) | LenE exp1 | LiftE exp1 | TheE exp1
  | UncaseE (exp1, _) | CvtE (exp1, _, _) ->
    collect_exp_calls t static_typ_env static_def_env origin acc exp1
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CompE (left, right) | MemE (left, right) | CatE (left, right)
  | IdxE (left, right) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc left in
    collect_exp_calls t static_typ_env static_def_env origin acc right
  | IfE (cond, then_exp, else_exp) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc cond in
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc then_exp in
    collect_exp_calls t static_typ_env static_def_env origin acc else_exp
  | TupE exps | ListE exps ->
    List.fold_left
      (collect_exp_calls t static_typ_env static_def_env origin)
      acc
      exps
  | CaseE (_, exp1) ->
    collect_exp_calls t static_typ_env static_def_env origin acc exp1
  | OptE None -> acc
  | OptE (Some exp1) ->
    collect_exp_calls t static_typ_env static_def_env origin acc exp1
  | StrE fields ->
    fields
    |> List.map snd
    |> List.fold_left
         (collect_exp_calls t static_typ_env static_def_env origin)
         acc
  | DotE (record, _) ->
    collect_exp_calls t static_typ_env static_def_env origin acc record
  | SliceE (source, start, stop) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc source in
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc start in
    collect_exp_calls t static_typ_env static_def_env origin acc stop
  | UpdE (record, path, value) | ExtE (record, path, value) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc record in
    let acc = collect_path_calls t static_typ_env static_def_env origin acc path in
    collect_exp_calls t static_typ_env static_def_env origin acc value
  | ProjE (exp1, _) ->
    collect_exp_calls t static_typ_env static_def_env origin acc exp1
  | CallE (_, args) ->
    args
    |> List.fold_left
         (fun acc arg ->
           match arg.it with
           | ExpA exp ->
             collect_exp_calls t static_typ_env static_def_env origin acc exp
           | TypA _ | DefA _ | GramA _ -> acc)
         acc
  | IterE (body, (_iter, generators)) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc body in
    generators
    |> List.map snd
    |> List.fold_left
         (collect_exp_calls t static_typ_env static_def_env origin)
         acc
  | SubE (exp1, _, _) ->
    collect_exp_calls t static_typ_env static_def_env origin acc exp1

and collect_path_calls t static_typ_env static_def_env origin acc path =
  match path.it with
  | RootP -> acc
  | IdxP (path, exp) ->
    let acc = collect_path_calls t static_typ_env static_def_env origin acc path in
    collect_exp_calls t static_typ_env static_def_env origin acc exp
  | SliceP (path, start, stop) ->
    let acc = collect_path_calls t static_typ_env static_def_env origin acc path in
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc start in
    collect_exp_calls t static_typ_env static_def_env origin acc stop
  | DotP (path, _) ->
    collect_path_calls t static_typ_env static_def_env origin acc path

let rec collect_prem_calls t static_typ_env static_def_env origin acc prem =
  match prem.it with
  | RulePr (_, args, _, exp) ->
    let acc =
      args
      |> List.fold_left
           (fun acc arg ->
             match arg.it with
             | ExpA exp ->
               collect_exp_calls t static_typ_env static_def_env origin acc exp
             | TypA _ | DefA _ | GramA _ -> acc)
           acc
    in
    collect_exp_calls t static_typ_env static_def_env origin acc exp
  | IfPr exp ->
    collect_exp_calls t static_typ_env static_def_env origin acc exp
  | LetPr (_quants, lhs, rhs) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc lhs in
    collect_exp_calls t static_typ_env static_def_env origin acc rhs
  | ElsePr -> acc
  | IterPr (prem, (_iter, generators)) ->
    let acc = collect_prem_calls t static_typ_env static_def_env origin acc prem in
    generators
    |> List.map snd
    |> List.fold_left
         (collect_exp_calls t static_typ_env static_def_env origin)
         acc
  | NegPr prem -> collect_prem_calls t static_typ_env static_def_env origin acc prem

let collect_clause_calls t static_typ_env static_def_env origin acc clause =
  match clause.it with
  | DefD (_binds, args, rhs, prems) ->
    let acc =
      args
      |> List.fold_left
           (fun acc arg ->
             match arg.it with
             | ExpA exp ->
               collect_exp_calls t static_typ_env static_def_env origin acc exp
             | TypA _ | DefA _ | GramA _ -> acc)
           acc
    in
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc rhs in
    List.fold_left
      (collect_prem_calls t static_typ_env static_def_env origin)
      acc
      prems

let collect_body_calls t static_typ_env static_def_env body =
  List.fold_left
    (collect_clause_calls t static_typ_env static_def_env body.body_origin)
    []
    body.body_clauses

let collect_rule_calls t static_typ_env static_def_env origin acc rule =
  match rule.it with
  | RuleD (_id, _binds, _mixop, exp, prems) ->
    let acc = collect_exp_calls t static_typ_env static_def_env origin acc exp in
    List.fold_left
      (collect_prem_calls t static_typ_env static_def_env origin)
      acc
      prems

let rec collect_relation_refs_from_prem acc prem =
  match prem.it with
  | RulePr (rel_id, _, _, _) ->
    if List.mem rel_id.it acc then acc else rel_id.it :: acc
  | IterPr (prem, _) | NegPr prem ->
    collect_relation_refs_from_prem acc prem
  | IfPr _ | LetPr _ | ElsePr -> acc

let collect_relation_refs_from_clause clause =
  match clause.it with
  | DefD (_, _, _, prems) ->
    prems
    |> List.fold_left collect_relation_refs_from_prem []
    |> List.rev

let add_ref id refs =
  if List.mem id refs then refs else id :: refs

let rec collect_definition_refs_from_exp refs exp =
  let collect = collect_definition_refs_from_exp in
  match exp.it with
  | VarE _ | BoolE _ | NumE _ | TextE _ -> refs
  | UnE (_, _, exp) | ProjE (exp, _) | UncaseE (exp, _) | TheE exp
  | DotE (exp, _) | LiftE exp | LenE exp | CvtE (exp, _, _)
  | SubE (exp, _, _) | CaseE (_, exp) -> collect refs exp
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CompE (left, right) | MemE (left, right) | CatE (left, right)
  | IdxE (left, right) -> collect (collect refs left) right
  | IfE (cond, then_exp, else_exp) ->
    collect (collect (collect refs cond) then_exp) else_exp
  | TupE exps | ListE exps -> List.fold_left collect refs exps
  | OptE None -> refs
  | OptE (Some exp) -> collect refs exp
  | StrE fields -> List.fold_left (fun refs (_, exp) -> collect refs exp) refs fields
  | SliceE (base, first, last) -> collect (collect (collect refs base) first) last
  | UpdE (base, path, value) | ExtE (base, path, value) ->
    collect (collect_definition_refs_from_path (collect refs base) path) value
  | CallE (id, args) ->
    List.fold_left collect_definition_refs_from_arg (add_ref id.it refs) args
  | IterE (body, (_, generators)) ->
    List.fold_left (fun refs (_, exp) -> collect refs exp) (collect refs body) generators

and collect_definition_refs_from_path refs path =
  match path.it with
  | RootP | DotP ({ it = RootP; _ }, _) -> refs
  | DotP (path, _) -> collect_definition_refs_from_path refs path
  | IdxP (path, exp) ->
    collect_definition_refs_from_exp
      (collect_definition_refs_from_path refs path) exp
  | SliceP (path, first, last) ->
    collect_definition_refs_from_exp
      (collect_definition_refs_from_exp
         (collect_definition_refs_from_path refs path) first) last

and collect_definition_refs_from_arg refs arg =
  match arg.it with
  | ExpA exp -> collect_definition_refs_from_exp refs exp
  | DefA id -> add_ref id.it refs
  | TypA _ | GramA _ -> refs

let rec collect_definition_refs_from_prem refs prem =
  match prem.it with
  | RulePr (_, args, _, exp) ->
    collect_definition_refs_from_exp
      (List.fold_left collect_definition_refs_from_arg refs args) exp
  | IfPr exp -> collect_definition_refs_from_exp refs exp
  | LetPr (_, left, right) ->
    collect_definition_refs_from_exp
      (collect_definition_refs_from_exp refs left) right
  | ElsePr -> refs
  | IterPr (prem, (_, generators)) ->
    List.fold_left
      (fun refs (_, exp) -> collect_definition_refs_from_exp refs exp)
      (collect_definition_refs_from_prem refs prem) generators
  | NegPr prem -> collect_definition_refs_from_prem refs prem

let raw_definition_refs_of_body body =
  body.body_clauses
  |> List.fold_left (fun refs clause ->
    match clause.it with
    | DefD (_, args, rhs, prems) ->
      let refs = List.fold_left collect_definition_refs_from_arg refs args in
      let refs = collect_definition_refs_from_exp refs rhs in
      List.fold_left collect_definition_refs_from_prem refs prems)
    []
  |> List.rev

let rec premise_uses_annotated_execution t prem =
  match prem.it with
  | RulePr (id, _, _, _) ->
    (match Relation_analysis.find_relation t.relation_analysis id.it with
    | Some relation ->
      relation.maude_equational_view
      && (relation.kind = Relation_graph.Execution
          || relation.kind = Relation_graph.Execution_star)
    | None -> false)
  | IterPr (prem, _) | NegPr prem -> premise_uses_annotated_execution t prem
  | IfPr _ | LetPr _ | ElsePr -> false

let source_ids exp =
  Il.Free.(free_exp exp).varid
  |> Il.Free.Set.to_seq
  |> List.of_seq
  |> List.sort_uniq String.compare

let add_source_ids bound exp =
  List.sort_uniq String.compare (source_ids exp @ bound)

let source_ids_bound bound exp =
  source_ids exp |> List.for_all (fun id -> List.mem id bound)

let general_flat_membership_source exp =
  match exp.note.it with
  | IterT ({ it = IterT _; _ }, _) -> false
  | IterT (_, (List | List1 | ListN _)) -> true
  | VarT _ | BoolT | NumT _ | TextT | TupT _ | IterT (_, Opt) -> false

let rec if_premise_rewrite_need bound exp =
  match exp.it with
  | BinE (`AndOp, _, left, right) ->
    let left_needs, bound = if_premise_rewrite_need bound left in
    let right_needs, bound = if_premise_rewrite_need bound right in
    left_needs || right_needs, bound
  | MemE (left, right) ->
    let introduced =
      source_ids left |> List.filter (fun id -> not (List.mem id bound))
    in
    ( introduced <> [] && general_flat_membership_source right
    , List.sort_uniq String.compare (introduced @ bound) )
  | CmpE (`EqOp, _, ({ it = VarE _; _ } as left), right)
    when source_ids_bound bound right ->
    false, add_source_ids bound left
  | CmpE (`EqOp, _, left, ({ it = VarE _; _ } as right))
    when source_ids_bound bound left ->
    false, add_source_ids bound right
  | _ -> false, bound

let premise_rewrite_need bound prem =
  match prem.it with
  | IfPr exp -> if_premise_rewrite_need bound exp
  | LetPr (_, left, right) when source_ids_bound bound right ->
    false, add_source_ids bound left
  | RulePr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> false, bound

let clause_uses_binding_membership clause =
  match clause.it with
  | DefD (_, args, _, prems) ->
    let bound =
      args
      |> List.fold_left (fun bound arg ->
        match arg.it with
        | ExpA exp -> add_source_ids bound exp
        | TypA _ | DefA _ | GramA _ -> bound) []
    in
    let needs, _ =
      prems
      |> List.fold_left (fun (needs, bound) prem ->
        let prem_needs, bound = premise_rewrite_need bound prem in
        needs || prem_needs, bound) (false, bound)
    in
    needs

let body_needs_rewrite t body =
  List.exists (fun clause ->
    match clause.it with
    | DefD (_, _, _, prems) ->
      clause_uses_binding_membership clause
      || List.exists (premise_uses_annotated_execution t) prems)
    body.body_clauses

let specialization_for_identity t identity =
  specializations_for t identity.def_id
  |> List.find_opt (fun specialization ->
    specialization.key_components = identity.specialization_key)

let identities_for_body t body =
  if definition_body_has_static_params body.body_params then
    specializations_for t body.body_id.it
    |> List.map identity_of_specialization
  else
    [ plain_identity body.body_id.it ]

let identity_context t identity =
  match specialization_for_identity t identity with
  | None -> [], []
  | Some specialization ->
    ( specialization.static_typs
      |> List.map (fun (binding : static_typ_binding) ->
        binding.param_id, binding.typ)
    , specialization.static_defs
      |> List.map (fun (binding : static_def_binding) ->
        binding.param_id, binding.target_id) )

let identity_edges t body identity =
  let static_typ_env, static_def_env = identity_context t identity in
  let specialized =
    collect_body_calls t static_typ_env static_def_env body
    |> List.map identity_of_specialization
  in
  let plain =
    raw_definition_refs_of_body body
    |> List.filter_map (fun id ->
      let id = Option.value ~default:id (List.assoc_opt id static_def_env) in
      match Hashtbl.find_opt t.bodies_by_id id with
      | Some target when definition_body_has_static_params target.body_params -> None
      | Some _ -> Some (plain_identity id)
      | None -> None)
  in
  specialized @ plain
  |> List.sort_uniq (fun left right -> String.compare (identity_key left) (identity_key right))

let compute_rewrite_backed_definitions t =
  Hashtbl.iter (fun _ body ->
    identities_for_body t body
    |> List.iter (fun identity ->
      Hashtbl.replace t.definition_identity_edges
        (identity_key identity) (identity_edges t body identity);
      if body_needs_rewrite t body then
        Hashtbl.replace t.rewrite_backed_identities (identity_key identity) ()))
    t.bodies_by_id;
  let changed = ref true in
  while !changed do
    changed := false;
    Hashtbl.iter (fun caller callees ->
      if not (Hashtbl.mem t.rewrite_backed_identities caller)
         && List.exists
              (fun callee ->
                Hashtbl.mem t.rewrite_backed_identities (identity_key callee))
              callees
      then (
        Hashtbl.replace t.rewrite_backed_identities caller ();
        changed := true))
      t.definition_identity_edges
  done

let add_specialization t queue specialization =
  if has_specialization t specialization then
    ()
  else (
    let old = specializations_for t specialization.def_id in
    Hashtbl.replace
      t.specializations_by_id
      specialization.def_id
      (old @ [ specialization ]);
    queue := !queue @ [ specialization ])

let add_violation t violation =
  t.violations <- t.violations @ [ violation ]

let record_specialization_cap t steps queue =
  match queue with
  | [] -> ()
  | (specialization : specialization) :: _ ->
    add_violation t
      { origin = specialization.origin
      ; constructor = "FunctionGraph/static-specialization/finite-cap"
      ; reason =
          (Printf.sprintf
             "finite static specialization worklist reached cap %d after %d processed item(s); pending specialization `%s` with key `%s` was not explored"
             finite_specialization_cap
             steps
             specialization.def_id
             (String.concat "," specialization.key_components))
      ; suggestion =
          Some
            "Keep this specialization Unsupported until the static argument closure is proven finite or the cap is raised with evidence"
      ; source_echo = specialization.origin.Origin.source_echo
      }

let compute_specializations t =
  let queue = ref [] in
  Hashtbl.iter
    (fun _id body ->
      if not (definition_body_has_static_params body.body_params) then
        collect_body_calls t [] [] body
        |> List.iter (add_specialization t queue))
    t.bodies_by_id;
  Relation_analysis.relation_bodies t.relation_analysis
  |> List.iter (fun (body : Relation_analysis.relation_body) ->
    body.relation_rules
    |> List.fold_left
         (collect_rule_calls t [] [] body.relation_origin)
         []
    |> List.iter (add_specialization t queue));
  let rec drain steps =
    match !queue with
    | [] -> ()
    | _ when steps >= finite_specialization_cap ->
      record_specialization_cap t steps !queue;
      queue := []
    | specialization :: rest ->
      queue := rest;
      (match Hashtbl.find_opt t.bodies_by_id specialization.def_id with
      | None -> ()
      | Some body ->
        let static_typ_env =
          specialization.static_typs
          |> List.map
               (fun (binding : static_typ_binding) ->
                 binding.param_id, binding.typ)
        in
        let static_def_env =
          specialization.static_defs
          |> List.map
               (fun (binding : static_def_binding) ->
                 binding.param_id, binding.target_id)
        in
        collect_body_calls t static_typ_env static_def_env body
        |> List.iter (add_specialization t queue));
      drain (steps + 1)
  in
  drain 0

let inverse_hint_target (hint : hint) =
  if hint.hintid.it <> "inverse" then
    None
  else
    match hint.hintexp.it with
    | El.Ast.CallE (id, [])
    | El.Ast.VarE (id, []) -> Some id.it
    | _ -> None

let dec_hint_names entries =
  let table = Hashtbl.create 127 in
  entries
  |> List.iter (fun (entry : Source_index.entry) ->
    match entry.def.it with
    | HintD hintdef ->
      (match hintdef.it with
      | DecH (id, hints) ->
        let names = List.map (fun hint -> hint.hintid.it) hints in
        Hashtbl.replace table id.it names
      | TypH _ | RelH _ | GramH _ | RuleH _ -> ())
    | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> ());
  table

let dec_has_hint table id name =
  match Hashtbl.find_opt table id with
  | None -> false
  | Some names -> List.mem name names

let split_last items =
  match List.rev items with
  | [] -> None
  | last :: rev_prefix -> Some (List.rev rev_prefix, last)

let inverse_signature_compatible source_params source_result inverse_params inverse_result =
  match split_last inverse_params with
  | Some (known_params, { it = ExpP (_, inverse_arg); _ })
    when Il.Eq.eq_typ source_result inverse_arg ->
    source_params
    |> List.mapi (fun index param -> index, param)
    |> List.exists (fun (index, omitted) ->
      match omitted.it with
      | ExpP (_, omitted_typ) ->
        let remaining =
          source_params
          |> List.mapi (fun current param -> current, param)
          |> List.filter_map (fun (current, param) ->
            if current = index then None else Some param)
        in
        Il.Eq.eq_typ omitted_typ inverse_result
        && List.length remaining = List.length known_params
        && List.for_all2 Il.Eq.eq_param remaining known_params
      | TypP _ | DefP _ | GramP _ -> false)
  | _ -> false

let invalid_inverse t source_id hint_origin reason =
  Hashtbl.replace
    t.inverse_statuses_by_id source_id
    (Invalid_inverse { reason; hint_origin });
  ()

let validate_inverse_hint t hint_origin source_id hint =
  match inverse_hint_target hint with
  | None ->
    invalid_inverse t source_id hint_origin
      "inverse hint payload is not a direct zero-argument definition reference"
  | Some inverse_id ->
    (match
       Hashtbl.find_opt t.bodies_by_id source_id,
       Hashtbl.find_opt t.bodies_by_id inverse_id,
       Hashtbl.find_opt t.definitions_by_id source_id,
       Hashtbl.find_opt t.definitions_by_id inverse_id
     with
    | Some source_body, Some inverse_body, Some source, Some inverse
      when inverse_signature_compatible
             source_body.body_params source.result
             inverse_body.body_params inverse.result ->
      Hashtbl.replace
        t.inverse_statuses_by_id source_id (Valid_inverse inverse_id)
    | None, _, _, _ ->
      invalid_inverse t source_id hint_origin
        ("inverse metadata source `" ^ source_id ^ "` has no DecD declaration")
    | _, None, _, _ | _, _, _, None ->
      invalid_inverse t source_id hint_origin
        ("inverse target `" ^ inverse_id ^ "` has no DecD declaration")
    | _ ->
      invalid_inverse t source_id hint_origin
        ("inverse target `" ^ inverse_id
         ^ "` does not structurally swap the forward final argument and result"))

let validate_inverse_metadata t entries =
  t.definitions
  |> List.iter (fun (definition : definition) ->
    Hashtbl.replace t.inverse_statuses_by_id definition.id No_inverse);
  entries
  |> List.iter (fun (entry : Source_index.entry) ->
    match entry.def.it with
    | HintD { it = DecH (id, hints); _ } ->
      hints
      |> List.iter (fun hint ->
        if hint.hintid.it = "inverse" then
          validate_inverse_hint t entry.origin id.it hint)
    | HintD _ | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ -> ())

let build index =
  let definitions_by_id = Hashtbl.create 127 in
  let bodies_by_id = Hashtbl.create 127 in
  let definition_identity_edges = Hashtbl.create 127 in
  let rewrite_backed_identities = Hashtbl.create 31 in
  let specializations_by_id = Hashtbl.create 127 in
  let definitions = ref [] in
  let decd_relation_seeds = ref [] in
  let entries = Source_index.entries index in
  let dec_hints_by_id = dec_hint_names entries in
  let relation_analysis = Relation_analysis.build index in
  entries
  |> List.iter (fun (entry : Source_index.entry) ->
    match entry.def.it with
    | DecD (id, params, result, clauses) ->
      let definition =
        { id = id.it
        ; origin = entry.origin
        ; params = List.map param_kind params
        ; result
        ; clause_count = List.length clauses
        ; partial = dec_has_hint dec_hints_by_id id.it "partial"
        }
      in
      definitions := definition :: !definitions;
      add_once definitions_by_id id.it definition;
      add_once
        bodies_by_id
        id.it
        { body_id = id
        ; body_origin = entry.origin
        ; body_params = params
        ; body_clauses = clauses
        };
      clauses
      |> List.map collect_relation_refs_from_clause
      |> List.concat
      |> List.sort_uniq String.compare
      |> List.iter (fun rel_id ->
        decd_relation_seeds :=
          (rel_id, id.it)
          :: !decd_relation_seeds)
    | TypD _ | RelD _ | GramD _ | RecD _ | HintD _ -> ());
  { definitions = List.rev !definitions
  ; definitions_by_id
  ; bodies_by_id
  ; definition_identity_edges
  ; rewrite_backed_identities
  ; specializations_by_id
  ; inverse_statuses_by_id = Hashtbl.create 31
  ; relation_analysis
  ; violations = []
  }
  |> fun t ->
  validate_inverse_metadata t entries;
  compute_specializations t;
  compute_rewrite_backed_definitions t;
  Relation_analysis.compute_runtime_demands
    t.relation_analysis !decd_relation_seeds;
  t

let diagnostics ~profile t =
  t.violations
  |> List.map (fun (violation : violation) ->
    Diagnostics.make
      ?suggestion:violation.suggestion
      ?source_echo:violation.source_echo
      ~category:Diagnostics.Unsupported
      ~origin:violation.origin
      ~constructor:violation.constructor
      ~enclosing:
        (Diagnostic_provenance.enclosing ~context:[] violation.origin)
      ~profile
      ~reason:violation.reason
      ())

let definitions t = t.definitions

let find_definition t id =
  Hashtbl.find_opt t.definitions_by_id id

let definition_inverse t id =
  match Hashtbl.find_opt t.inverse_statuses_by_id id with
  | Some (Valid_inverse inverse_id) -> Some inverse_id
  | Some No_inverse | Some (Invalid_inverse _) | None -> None

let definition_is_partial t id =
  match find_definition t id with
  | Some definition -> definition.partial
  | None -> false

let definition_is_rewrite_backed t id =
  Hashtbl.mem t.rewrite_backed_identities (identity_key (plain_identity id))
  || specializations_for t id
     |> List.exists (fun specialization ->
       Hashtbl.mem t.rewrite_backed_identities
         (identity_key (identity_of_specialization specialization)))

let identity_is_rewrite_backed t identity =
  Hashtbl.mem t.rewrite_backed_identities (identity_key identity)

let definition_is_runtime_entry t id =
  let incoming =
    Hashtbl.fold
      (fun _caller callees incoming ->
        incoming
        || List.exists
             (fun (callee : definition_identity) ->
               String.equal callee.def_id id)
             callees)
      t.definition_identity_edges false
  in
  match Hashtbl.find_opt t.definitions_by_id id with
  | None -> false
  | Some definition ->
    let runtime_component typ =
      Relation_analysis.relations t.relation_analysis
      |> List.exists (fun (relation : Relation_analysis.relation) ->
        match relation.kind, relation.result.it with
        | (Relation_graph.Execution | Relation_graph.Execution_star), TupT fields ->
          List.exists (fun (_, field_typ) -> Il.Eq.eq_typ typ field_typ) fields
        | (Relation_graph.Execution | Relation_graph.Execution_star), _ ->
          Il.Eq.eq_typ typ relation.result
        | (Relation_graph.Deterministic_candidate
          | Relation_graph.Predicate_candidate
          | Relation_graph.Unknown), _ -> false)
    in
    not incoming
    && definition.clause_count > 0
    && not
         (List.exists
            (function Static_typ | Static_def | Static_gram -> true
              | Runtime_exp -> false)
            definition.params)
    && runtime_component definition.result

let emitted_definitions t =
  t.definitions
  |> List.concat_map (fun (definition : definition) ->
    let emitted identity op_name =
      { identity
      ; source_id = definition.id
      ; op_name
      ; result = definition.result
      ; rewrite_backed = identity_is_rewrite_backed t identity
      }
    in
    if List.exists (function Static_def -> true | _ -> false) definition.params then
      specializations_for t definition.id
      |> List.map (fun specialization ->
        let target_ids =
          specialization.static_defs
          |> List.map (fun binding -> binding.target_id)
        in
        emitted (identity_of_specialization specialization)
          (Naming.specialized_definition_op
             (definition.id $ no_region)
             target_ids))
    else
      [ emitted (plain_identity definition.id)
          (Naming.definition_op (definition.id $ no_region)) ])

let emitted_definition t identity =
  emitted_definitions t
  |> List.find_opt (fun (definition : emitted_definition) ->
    definition.identity = identity)

let definition_inverse_status t id =
  match Hashtbl.find_opt t.inverse_statuses_by_id id with
  | Some status -> status
  | None -> No_inverse

let relation_analysis t = t.relation_analysis
