open Il.Ast

type result =
  | Certified
  | Blocked of string

let split_last_two values =
  match List.rev values with
  | right :: left :: prefix -> Some (List.rev prefix, left, right)
  | _ -> None

let split_at count values =
  let rec split count prefix values =
    if count = 0 then Some (List.rev prefix, values)
    else
      match values with
      | [] -> None
      | value :: values -> split (count - 1) (value :: prefix) values
  in
  split count [] values

let free_ids exp =
  Il.Free.(free_exp exp).varid |> Il.Free.Set.elements

let add_ids bound ids =
  List.fold_left
    (fun bound id -> if List.mem id bound then bound else id :: bound)
    bound ids

let rec pattern_bindings (exp : Il.Ast.exp) =
  let combine bindings =
    if List.exists Option.is_none bindings then None
    else
      let ids = List.concat_map (Option.value ~default:[]) bindings in
      if List.length ids = List.length (List.sort_uniq String.compare ids) then
        Some ids
      else None
  in
  match exp.it with
  | VarE id -> Some (if id.it = "_" then [] else [ id.it ])
  | TupE exps | ListE exps -> combine (List.map pattern_bindings exps)
  | StrE fields ->
    combine (List.map (fun (_, exp) -> pattern_bindings exp) fields)
  | CaseE (_, arg) | OptE (Some arg) | TheE arg | LiftE arg ->
    pattern_bindings arg
  | BoolE _ | NumE _ | TextE _ | OptE None -> Some []
  | UnE _ | BinE _ | CmpE _ | ProjE _ | UncaseE _ | DotE _ | CompE _
  | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _
  | IfE _ | CallE _ | IterE _ | CvtE _ | SubE _ -> None

let rec irrefutable_payload_bindings (exp : Il.Ast.exp) =
  let combine bindings =
    if List.exists Option.is_none bindings then None
    else
      let ids = List.concat_map (Option.value ~default:[]) bindings in
      if List.length ids = List.length (List.sort_uniq String.compare ids) then
        Some ids
      else None
  in
  match exp.it with
  | VarE id -> Some (if id.it = "_" then [] else [ id.it ])
  | TupE exps -> combine (List.map irrefutable_payload_bindings exps)
  | StrE fields ->
    combine
      (List.map (fun (_, field) -> irrefutable_payload_bindings field) fields)
  | LiftE inner -> irrefutable_payload_bindings inner
  | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _ | ProjE _
  | CaseE _ | UncaseE _ | OptE _ | TheE _ | DotE _ | CompE _ | ListE _
  | MemE _ | LenE _ | CatE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _
  | IfE _ | CallE _ | IterE _ | CvtE _ | SubE _ -> None

let rec functional_path bound (path : Il.Ast.path) =
  match path.it with
  | RootP -> true
  | IdxP (path, index) ->
    functional_path bound path && functional_exp bound index
  | SliceP (path, start, length) ->
    functional_path bound path
    && functional_exp bound start
    && functional_exp bound length
  | DotP (path, _) -> functional_path bound path

and functional_exp bound (exp : Il.Ast.exp) =
  let all exps = List.for_all (functional_exp bound) exps in
  match exp.it with
  | VarE id -> id.it <> "_" && List.mem id.it bound
  | BoolE _ | NumE _ | TextE _ | OptE None -> true
  | UnE (_, _, exp) | ProjE (exp, _) | TheE exp | LiftE exp | LenE exp
  | CvtE (exp, _, _) | SubE (exp, _, _) ->
    functional_exp bound exp
  | BinE (_, _, left, right) | CmpE (_, _, left, right)
  | CatE (left, right) | IdxE (left, right) ->
    functional_exp bound left && functional_exp bound right
  | TupE exps | ListE exps -> all exps
  | StrE fields -> all (List.map snd fields)
  | CaseE (_, arg) | UncaseE (arg, _) | OptE (Some arg) ->
    functional_exp bound arg
  | DotE (exp, _) -> functional_exp bound exp
  | SliceE (base, start, length) -> all [ base; start; length ]
  | UpdE (base, path, value) | ExtE (base, path, value) ->
    functional_exp bound base
    && functional_path bound path
    && functional_exp bound value
  | IfE (cond, yes, no) -> all [ cond; yes; no ]
  | CompE (left, right) -> all [ left; right ]
  | MemE (left, right) -> all [ left; right ]
  | CallE _ | IterE _ -> false

let equality_binding bound (prem : Il.Ast.prem) =
  let bind (pattern : Il.Ast.exp) (value : Il.Ast.exp) =
    match pattern.it with
    | VarE id
      when id.it <> "_"
           && not (List.mem id.it bound)
           && functional_exp bound value ->
      Some id.it
    | _ -> None
  in
  match prem.it with
  | IfPr { it = CmpE (`EqOp, _, left, right); _ } ->
    (match bind left right with
    | Some _ as binding -> binding
    | None -> bind right left)
  | RulePr _ | IfPr _ | LetPr _ | ElsePr | IterPr _ | NegPr _ -> None

let witness_is_functional ctx origin known witness prems =
  let bound =
    known
    |> List.map pattern_bindings
    |> List.fold_left
         (fun bound -> function
           | Some ids -> add_ids bound ids
           | None -> bound)
         []
  in
  let bound =
    List.fold_left
      (fun bound prem ->
        match equality_binding bound prem with
        | Some id -> add_ids bound [ id ]
        | None -> bound)
      bound prems
  in
  functional_exp bound witness
  && Runtime_truth_totality.source_total ctx ~bound origin witness

let constructor_case ctx (exp : Il.Ast.exp) =
  match exp.it with
  | CaseE (mixop, arg) ->
    let arity = Xl.Mixop.arity mixop in
    (match irrefutable_payload_bindings arg,
           Typcase_constructor.resolve_emitted ctx exp.note mixop ~arity with
    | Some _, Typcase_constructor.Found resolution ->
      Ok resolution.registry_entry
    | None, _ -> Error "constructor payload is not an irrefutable source pattern"
    | Some _, Typcase_constructor.Missing ->
      Error "constructor has no emitted registry entry"
    | Some _, Typcase_constructor.Blocked reason -> Error reason
    | Some _, Typcase_constructor.Ambiguous _ ->
      Error "constructor registry lookup is ambiguous")
  | _ -> Error "seed input is not a constructor pattern"

let same_family left right =
  left.Constructor_registry.source_category = right.Constructor_registry.source_category
  && left.static_args_key = right.static_args_key

let closed_constructor_partition ctx entries =
  match entries with
  | [] -> Error "target-chain relation has no non-recursive seed RuleD"
  | first :: _ when not (List.for_all (same_family first) entries) ->
    Error "seed constructors do not belong to one source constructor family"
  | first :: _ ->
    let constructors = Context.constructors ctx in
    (match
       Constructor_registry.family_coverage constructors
         ~source_category:first.source_category
         ~static_args_key:first.static_args_key
     with
    | Constructor_registry.Open reasons -> Error (String.concat "; " reasons)
    | Constructor_registry.Closed family ->
      let names entries =
        entries
        |> List.map (fun entry -> entry.Constructor_registry.constructor_op)
        |> List.sort_uniq String.compare
      in
      let seeds = names entries in
      if List.length seeds <> List.length entries then
        Error "more than one seed RuleD matches the same source constructor"
      else if seeds <> names family then
        Error "seed RuleD constructors do not cover the closed source family"
      else Ok ())

let seed_partition ctx relation target =
  let known_count = target.Runtime_witness_proof.prefix_arity + 1 in
  let seeds =
    relation.Runtime_truth_worklist_core.rules
    |> List.filter (fun (rule : Runtime_truth_scc.rule) ->
         not
           (Source_rule_identity.equal_rule
              target.rule.identity rule.Runtime_truth_scc.source.identity))
  in
  let heads =
    seeds
    |> List.map (fun (rule : Runtime_truth_scc.rule) ->
         match
           split_at known_count
             (Analysis.Relation_graph.exp_components rule.source.head)
         with
         | Some (known, [ witness ]) -> Ok (rule, known, witness)
         | _ -> Error "seed RuleD does not expose one witness component")
  in
  match List.find_opt Result.is_error heads with
  | Some (Error reason) -> Error reason
  | Some (Ok _) | None ->
    let heads = List.filter_map Result.to_option heads in
    let rec discriminator index =
      if index = known_count then
        Error "seed RuleD heads have no closed constructor discriminator"
      else
        let cases =
          heads
          |> List.map (fun (_, known, _) -> constructor_case ctx (List.nth known index))
        in
        match List.find_opt Result.is_error cases with
        | Some _ -> discriminator (index + 1)
        | None ->
          let entries = List.filter_map Result.to_option cases in
          (match closed_constructor_partition ctx entries with
          | Error _ -> discriminator (index + 1)
          | Ok () ->
            let other_inputs_are_open =
              heads
              |> List.for_all (fun (_, known, _) ->
                   known
                   |> List.mapi (fun i exp -> i, exp)
                   |> List.for_all (fun (i, (exp : Il.Ast.exp)) ->
                        i = index ||
                        match exp.it with VarE _ -> true | _ -> false))
            in
            if not other_inputs_are_open then
              Error "a non-discriminator seed input is not an open variable pattern"
            else if
              heads
              |> List.for_all (fun ((rule : Runtime_truth_scc.rule), known, witness) ->
                   witness_is_functional
                     ctx rule.source.origin known witness rule.source.prems)
            then Ok ()
            else
              Error
                "a seed witness is not a total constructor value determined by its source-ordered premises")
    in
    discriminator 0

let has_sub_marker mixop =
  Xl.Mixop.flatten mixop
  |> List.exists
       (List.exists (fun (atom : Xl.Atom.atom) -> atom.it = Xl.Atom.Sub))

let direct_var (exp : Il.Ast.exp) =
  match exp.it with
  | VarE id -> Some id.it
  | _ -> None

let contains id exp = List.mem id (free_ids exp)

let delegates_endpoints domain_id rule =
  match rule.Runtime_truth_scc.source.prems with
  | [ { it = RulePr (id, [], _, exp); _ } ] when id.it = domain_id ->
    (match
       split_last_two
         (Analysis.Relation_graph.exp_components rule.source.head),
       split_last_two (Analysis.Relation_graph.exp_components exp)
     with
    | Some (head_prefix, head_left, head_right),
      Some (prem_prefix, prem_left, prem_right) ->
      (match direct_var prem_left, direct_var prem_right with
      | Some left, Some right ->
        List.length head_prefix = List.length prem_prefix
        && List.for_all2 Il.Eq.eq_exp head_prefix prem_prefix
        && contains left head_left && not (contains right head_left)
        && contains right head_right && not (contains left head_right)
      | _ -> false)
    | _ -> false)
  | _ -> false

let target_preorder ctx plan relations target =
  match Analysis.Function_graph.find_relation
          (Context.function_graph ctx) target.Runtime_witness_proof.target_rel_id with
  | None -> Error "target relation is absent from the source relation graph"
  | Some source_relation when not (has_sub_marker source_relation.mixop) ->
    Error "target relation is not marked by the SpecTec subtype operator"
  | Some _ ->
    let domains =
      plan.Runtime_truth_scc.successor_domains
      |> List.filter Runtime_truth_successor_domain.decision_complete
      |> List.map (fun domain ->
           domain.Runtime_truth_successor_domain.transitive.rule.relation_id)
      |> List.sort_uniq String.compare
    in
    (match
       Runtime_truth_worklist_core.find_relation
         relations target.target_rel_id
     with
    | None -> Error "target relation has no complete runtime carrier"
    | Some relation ->
      domains
      |> List.find_opt (fun domain_id ->
           relation.rules <> []
           && List.for_all (delegates_endpoints domain_id) relation.rules)
      |> function
      | Some _ -> Ok ()
      | None ->
        Error
          "target subtype relation is not a direct endpoint-preserving lift of one source-complete transitive domain")

(* A closed constructor partition selects at most one seed RuleD.  Functional
   source-ordered bindings make that rule's witness unique when it exists.  The
   materializer separately refutes seed absence, so the lifted subtype decision
   decides the complete least target-chain fixed point. *)
let decide ctx plan relations relation target =
  if not (Runtime_truth_scc.decision_complete plan) then
    Blocked "the runtime truth SCC has no source-complete false decision"
  else
    match seed_partition ctx relation target with
    | Error reason -> Blocked reason
    | Ok () ->
      (match target_preorder ctx plan relations target with
      | Ok () -> Certified
      | Error reason -> Blocked reason)
