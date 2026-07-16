open Il.Ast
open Util.Source

type blocker =
  { origin : Origin.t
  ; constructor : string
  ; reason : string
  ; source_echo : string option
  }

type certificate = Total | Blocked of blocker list

let rec nth_opt items index =
  match items, index with
  | item :: _, 0 -> Some item
  | _ :: rest, index when index > 0 -> nth_opt rest (index - 1)
  | _ -> None

let rec all_some acc = function
  | [] -> Some (List.rev acc)
  | Some item :: rest -> all_some (item :: acc) rest
  | None :: _ -> None

let exp_constructor = function
  | VarE _ -> "VarE" | BoolE _ -> "BoolE" | NumE _ -> "NumE"
  | TextE _ -> "TextE" | UnE _ -> "UnE" | BinE _ -> "BinE"
  | CmpE _ -> "CmpE" | TupE _ -> "TupE" | ProjE _ -> "ProjE"
  | CaseE _ -> "CaseE" | UncaseE _ -> "UncaseE" | OptE _ -> "OptE"
  | TheE _ -> "TheE" | StrE _ -> "StrE" | DotE _ -> "DotE"
  | CompE _ -> "CompE" | ListE _ -> "ListE" | LiftE _ -> "LiftE"
  | MemE _ -> "MemE" | LenE _ -> "LenE" | CatE _ -> "CatE"
  | IdxE _ -> "IdxE" | SliceE _ -> "SliceE" | UpdE _ -> "UpdE"
  | ExtE _ -> "ExtE" | IfE _ -> "IfE" | CallE _ -> "CallE"
  | IterE _ -> "IterE" | CvtE _ -> "CvtE" | SubE _ -> "SubE"

let blocker origin exp suffix reason =
  let ast_constructor = exp_constructor exp.it in
  { origin =
      Origin.with_child origin ast_constructor ~ast_constructor exp.at
        ~source_echo:(Il.Print.string_of_exp exp)
  ; constructor = "RuntimeTruthTotalEquality/" ^ ast_constructor ^ "/" ^ suffix
  ; reason
  ; source_echo = Some (Il.Print.string_of_exp exp)
  }

let source_condition_blocker origin exp ~reason =
  blocker origin exp "source-condition-certificate" reason

let premise_blocker origin prem suffix reason =
  { origin =
      Origin.with_child origin ("premise/" ^ suffix)
        ~ast_constructor:"Premise" prem.at
        ~source_echo:(Il.Print.string_of_prem prem)
  ; constructor = "RuntimeTruthTotalEquality/Premise/" ^ suffix
  ; reason
  ; source_echo = Some (Il.Print.string_of_prem prem)
  }

let combine certificates =
  let blockers = certificates |> List.concat_map (function Total -> [] | Blocked bs -> bs) in
  match blockers with [] -> Total | _ -> Blocked blockers

let add_ids ids bound = List.sort_uniq String.compare (ids @ bound)

type totality_facts =
  { lengths : (string * string) list
  ; length_domains : (string * Constructor_registry.entry) list
  ; validated_sequence_indices : Runtime_truth_successor_domain.total_fact list
  ; defined_indices : (string * string) list
  }

let empty_facts =
  { lengths = []
  ; length_domains = []
  ; validated_sequence_indices = []
  ; defined_indices = []
  }

let add_fact id token facts =
  { facts with lengths = (id, token) :: List.remove_assoc id facts.lengths }

let rec length_token facts exp =
  match exp.it with
  | VarE id -> List.assoc_opt id.it facts.lengths
  | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner -> length_token facts inner
  | IterE ({ it = VarE body; _ },
      ((Opt | List | List1), [ generator, source ]))
    when body.it = generator.it -> length_token facts source
  | IterE ({ it = VarE body; _ },
      (ListN (count, _), [ generator, source ]))
    when body.it = generator.it ->
    (match count_token facts count, length_token facts source with
    | Some count_token, Some source_token when count_token = source_token ->
      Some source_token
    | Some _, Some _ | None, _ | _, None -> None)
  | IterE (_, (ListN ({ it = VarE count; _ }, Some _), [])) ->
    (* This token exists only when an enclosing source sequence pattern has
       already proved that [count] is a defined Nat length.  Evaluator ListN
       then emits one element for each index below that count. *)
    List.assoc_opt count.it facts.lengths
  | ListE exps -> Some ("length:" ^ string_of_int (List.length exps))
  | OptE None -> Some "length:0"
  | OptE (Some _) -> Some "length:1"
  | _ when Type_shape.typ_is_iter exp.note ->
    Some ("source:" ^ Digest.to_hex (Digest.string (Il.Print.string_of_exp exp)))
  | _ -> None

and count_token facts exp =
  match exp.it with
  | NumE (`Nat count) -> Some ("length:" ^ Z.to_string count)
  | VarE id -> List.assoc_opt id.it facts.lengths
  | SubE (inner, _, _) | CvtE (inner, _, _) -> count_token facts inner
  | _ -> None

let rec structurally_nonempty facts exp =
  match exp.it, exp.note.it with
  | ListE (_ :: _), _ | _, IterT (_, List1) -> true
  | (SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner), _ ->
    structurally_nonempty facts inner
  | _ ->
    (match length_token facts exp with
    | Some token when String.starts_with ~prefix:"length:" token ->
      token <> "length:0"
    | Some _ | None -> false)

let synchronized_tokens tokens =
  match tokens with
  | Some token :: rest ->
    List.for_all (function Some other -> other = token | None -> false) rest
  | [] | None :: _ -> false

let iteration_domain_is_structural facts iter generators =
  match generators with
  | [] -> false
  | (_, first) :: _ ->
    let tokens = List.map (fun (_, source) -> length_token facts source) generators in
    match iter with
    | List -> List.length generators = 1 || synchronized_tokens tokens
    | List1 ->
      structurally_nonempty facts first && synchronized_tokens tokens
    | Opt -> List.length generators = 1 || synchronized_tokens tokens
    | ListN (count, _) ->
      (match count_token facts count with
      | None -> false
      | Some count ->
        List.for_all (function Some token -> token = count | None -> false) tokens)

(* A source pattern [xs^n] binds [n] to the length of the matched sequence.
   In that clause-local environment, evaluator ListN(n, Some i) with no value
   generators enumerates exactly the defined Nat indices 0, ..., n - 1.  This
   is a domain proof only: it does not expose a ListN length token and cannot
   certify standalone/vacuous iterations. *)
let indexed_enumeration_domain facts iter generators =
  match iter, generators with
  | ListN ({ it = VarE count; _ }, Some _), [] ->
    List.mem_assoc count.it facts.lengths
  | (Opt | List | List1 | ListN _), _ -> false

let rec bind_pattern_facts token facts pattern =
  match token, pattern.it with
  | Some token, VarE id when Type_shape.typ_is_iter pattern.note ->
    add_fact id.it token facts
  | Some token, IterE ({ it = VarE body; _ },
      (ListN ({ it = VarE count; _ }, _), [ generator, source ]))
    when body.it = generator.it ->
    let facts = add_fact count.it token facts in
    let facts = add_fact generator.it token facts in
    bind_pattern_facts (Some token) facts source
  | Some token, IterE ({ it = VarE body; _ },
      ((List | List1), [ generator, source ]))
    when body.it = generator.it ->
    bind_pattern_facts (Some token) (add_fact generator.it token facts) source
  | token, SubE (inner, _, _) | token, CvtE (inner, _, _) | token, LiftE inner ->
    bind_pattern_facts token facts inner
  | token, TupE [ inner ] ->
    bind_pattern_facts token facts inner
  | _ -> facts

let rec pattern_ids exp =
  match exp.it with
  | VarE id -> [ id.it ]
  | TupE exps | ListE exps -> List.concat_map pattern_ids exps
  | CaseE (_, exp) | OptE (Some exp) | TheE exp | LiftE exp
  | CvtE (exp, _, _) | SubE (exp, _, _) -> pattern_ids exp
  | OptE None -> []
  | CatE (left, right) -> pattern_ids left @ pattern_ids right
  | StrE fields -> fields |> List.concat_map (fun (_, exp) -> pattern_ids exp)
  | IterE (body, (iter, generators)) ->
    let iter_ids = match iter with
      | ListN (count, id) -> pattern_ids count @ Option.to_list (Option.map (fun id -> id.it) id)
      | Opt | List | List1 -> [] in
    pattern_ids body @ iter_ids
    @ (generators |> List.concat_map (fun (id, source) -> id.it :: pattern_ids source))
  | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _ | ProjE _
  | UncaseE _ | DotE _ | CompE _ | MemE _ | LenE _ | IdxE _ | SliceE _
  | UpdE _ | ExtE _ | IfE _ | CallE _ -> []

let rec wildcard_pattern exp =
  match exp.it with
  | VarE _ -> true
  | TupE exps -> List.for_all wildcard_pattern exps
  | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner -> wildcard_pattern inner
  | IterE ({ it = VarE body; _ },
           ((List | List1 | ListN _), [ generator, { it = VarE _; _ } ])) ->
    body.it = generator.it
  | _ -> false

let empty_sequence_pattern exp =
  match exp.it with
  | ListE [] | OptE None -> true
  | _ -> false

let nonempty_sequence_pattern exp =
  match exp.it with
  | CatE (left, right) ->
    empty_sequence_pattern left = false && (match left.it with ListE _ | OptE _ -> true | _ -> false)
    || empty_sequence_pattern right = false && (match right.it with ListE _ | OptE _ -> true | _ -> false)
    || (Type_shape.typ_is_iter left.note && not (Type_shape.typ_is_iter right.note))
    || (not (Type_shape.typ_is_iter left.note) && Type_shape.typ_is_iter right.note)
  | ListE (_ :: _) | OptE (Some _) -> true
  | _ -> false

let constructor_pattern exp =
  let rec unwrap exp =
    match exp.it with
    | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner -> unwrap inner
    | _ -> exp
  in
  let exp = unwrap exp in
  match exp.it, Static_key.typ_ref ~env:(Static_key.of_static_typ_env []) exp.note with
  | CaseE (mixop, arg), Some key ->
    let arity = match arg.it with TupE exps -> List.length exps | _ -> 1 in
    Some (Naming.source_owner key.category_id, key.static_args_key, mixop, arity)
  | _ -> None

let pattern_shape exp =
  exp_constructor exp.it ^ "(" ^ Il.Print.string_of_exp exp ^ ")"

let definition_entry ctx id =
  Analysis.Source_index.find_by_id (Context.source_index ctx) id
  |> List.find_map (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | DecD (source_id, params, _, clauses) when source_id.it = id -> Some (params, clauses)
    | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> None)

let runtime_args params clause =
  match clause.it with
  | DefD (_, args, _, _) when List.length params = List.length args ->
    List.fold_left2 (fun patterns param arg ->
      match patterns, param.it, arg.it with
      | None, _, _ -> None
      | Some patterns, ExpP _, ExpA exp -> Some (exp :: patterns)
      | Some patterns, TypP _, TypA _ -> Some patterns
      | Some patterns, DefP _, DefA _ -> Some patterns
      | Some _, _, _ -> None)
      (Some []) params args
    |> Option.map List.rev
  | DefD _ -> None

let clause_shapes params clauses =
  clauses |> List.filter_map (runtime_args params)
  |> List.map (fun patterns -> String.concat ", " (List.map pattern_shape patterns))
  |> String.concat "; "

type clause_role = Unconditional | Guarded | Otherwise | Invalid

let fresh_pattern_id bound id =
  id.it = "_" || not (List.mem id.it bound)

let representation_preserving_type ctx source target =
  try Il.Eval.equiv_typ (Context.il_env ctx) source target with
  | Il.Eval.Irred -> false

let rec certified_binding_pattern ctx bound exp =
  let rec tuple bound = function
    | [] -> true
    | exp :: rest when certified_binding_pattern ctx bound exp ->
      tuple (add_ids (pattern_ids exp) bound) rest
    | _ -> false
  in
  let constructor_payload exp =
    match exp.it with
    | CaseE (_, { it = TupE exps; _ }) -> tuple bound exps
    | CaseE (_, arg) -> certified_binding_pattern ctx bound arg
    | _ -> false
  in
  match exp.it with
  | VarE id -> fresh_pattern_id bound id
  | TupE exps -> tuple bound exps
  | IterE ({ it = VarE body; _ },
      ((List | Opt), [ generator, { it = VarE source; _ } ])) ->
    body.it = generator.it && source.it <> "_"
    && fresh_pattern_id bound source
  | LiftE inner
    when representation_preserving_type ctx inner.note exp.note ->
    certified_binding_pattern ctx bound inner
  | CvtE (inner, source, target) when source = target ->
    certified_binding_pattern ctx bound inner
  | SubE (inner, source, target)
    when representation_preserving_type ctx source target ->
    certified_binding_pattern ctx bound inner
  | _ ->
  match constructor_pattern exp with
  | Some (category, key, mixop, arity) when constructor_payload exp ->
    let coverage =
       Constructor_registry.family_coverage (Context.constructors ctx)
         ~source_category:category ~static_args_key:key
    in
    (match coverage with
    | Constructor_registry.Closed [ entry ] ->
      entry.status = Constructor_registry.Emitted
      && entry.arity = arity && Il.Eq.eq_mixop entry.mixop mixop
    | Constructor_registry.Open _ -> false
    | Closed _ -> false)
  | Some _ -> false
  | None -> false

let binding_premise ctx bound prem =
  let binding pattern =
    let fresh =
      pattern_ids pattern |> List.filter (fun id -> not (List.mem id bound))
    in
    fresh <> [] && certified_binding_pattern ctx bound pattern
  in
  match prem.it with
  | LetPr (_, left, _) -> binding left
  | IfPr { it = CmpE (`EqOp, _, left, right); _ } ->
    binding left || binding right
  | IfPr _ | RulePr _ | ElsePr | IterPr _ | NegPr _ -> false

let clause_role ctx patterns clause =
  match clause.it with
  | DefD (_, _, _, prems) ->
    let bound = patterns |> List.concat_map pattern_ids in
    let else_count = List.fold_left (fun count prem ->
      match prem.it with ElsePr -> count + 1 | _ -> count) 0 prems in
    let ordinary = List.filter (fun prem -> prem.it <> ElsePr) prems in
    let bindings, guards = List.partition (binding_premise ctx bound) ordinary in
    if List.length bindings + List.length guards <> List.length ordinary
    then Invalid
    else match else_count, guards with
      | 0, [] -> Unconditional
      | 0, _ :: _ -> Guarded
      | 1, [] -> Otherwise
      | _ -> Invalid

type covered_clause =
  { clause : clause
  ; patterns : exp list
  ; allow_else : bool
  }

let complete_clause_group ctx group =
  let roles =
    List.map (fun (clause, patterns) -> clause_role ctx patterns clause) group
  in
  let rec guarded_partition saw_guard = function
    | [ Otherwise ] -> saw_guard
    | Guarded :: rest -> guarded_partition true rest
    | Unconditional :: _ | Otherwise :: _ | Invalid :: _ | [] -> false
  in
  let complete =
    List.exists (( = ) Unconditional) roles || guarded_partition false roles
  in
  if not complete then None else
    Some (List.map2 (fun (clause, patterns) role ->
      { clause; patterns; allow_else = role = Otherwise }) group roles)

let clause_key patterns =
  String.concat "\000" (List.map Il.Print.string_of_exp patterns)

let contiguous_clause_groups clauses =
  let rec group current_key current groups = function
    | [] -> List.rev (match current with [] -> groups | _ -> List.rev current :: groups)
    | ((_, patterns) as clause) :: rest ->
      let key = clause_key patterns in
      if current <> [] && key = current_key then
        group current_key (clause :: current) groups rest
      else
        let groups = match current with [] -> groups | _ -> List.rev current :: groups in
        group key [ clause ] groups rest
  in
  group "" [] [] clauses

let source_ordered_pattern_fallback ctx groups =
  match List.rev groups with
  | [ (clause, patterns) ] :: earlier
    when earlier <> []
         && List.for_all wildcard_pattern patterns
         && clause_role ctx patterns clause = Otherwise ->
    earlier |> List.rev |> List.map (complete_clause_group ctx) |> all_some []
    |> Option.map (fun groups ->
         List.concat groups @ [ { clause; patterns; allow_else = true } ])
  | _ -> None

let source_complete_clauses ctx params clauses =
  let clauses = clauses |> List.filter_map (fun clause ->
    Option.map (fun patterns -> clause, patterns) (runtime_args params clause)) in
  let groups = contiguous_clause_groups clauses in
  match source_ordered_pattern_fallback ctx groups with
  | Some clauses -> Some clauses
  | None ->
  match groups |> List.find_map (fun group ->
    match group with
    | (_, patterns) :: _ when List.for_all wildcard_pattern patterns ->
      complete_clause_group ctx group
    | _ -> None) with
  | Some clauses -> Some clauses
  | None ->
    let arity =
      match clauses with [] -> 0 | (_, patterns) :: _ -> List.length patterns
    in
    let rec discriminant index =
      if index = arity then None else
      let other_wild (_, patterns) =
        patterns |> List.mapi (fun i pattern -> i = index || wildcard_pattern pattern)
        |> List.for_all Fun.id
      in
      let candidate_groups = List.filter (function
        | clause :: _ -> other_wild clause
        | [] -> false) groups in
      let candidates = List.concat candidate_groups in
      let patterns =
        candidates
        |> List.map (fun (_, patterns) -> nth_opt patterns index)
        |> all_some []
      in
      let complete_candidates () =
        candidate_groups
        |> List.map (complete_clause_group ctx)
        |> all_some []
        |> Option.map List.concat
      in
      match patterns with
      | None -> discriminant (index + 1)
      | Some patterns when
          List.exists empty_sequence_pattern patterns
          && List.exists nonempty_sequence_pattern patterns ->
        complete_candidates ()
      | Some patterns ->
        let constructors = List.filter_map constructor_pattern patterns in
        match constructors with
        | [] -> discriminant (index + 1)
        | (category, key, _, _) :: _ ->
          (match Constructor_registry.family_coverage (Context.constructors ctx)
                   ~source_category:category ~static_args_key:key with
          | Constructor_registry.Open _ -> discriminant (index + 1)
          | Closed entries ->
            let represented entry =
              List.exists (fun (_, _, mixop, arity) ->
                Il.Eq.eq_mixop mixop entry.Constructor_registry.mixop
                && arity = entry.arity) constructors
            in
            if List.for_all represented entries then complete_candidates ()
            else discriminant (index + 1))
    in
    discriminant 0

let sequence_split exp =
  match exp.it with
  | CatE ({ it = ListE [ head ]; _ }, tail)
  | CatE (tail, { it = ListE [ head ]; _ }) -> Some (head, tail)
  | CatE ({ it = OptE (Some head); _ }, tail)
  | CatE (tail, { it = OptE (Some head); _ }) -> Some (head, tail)
  | CatE (left, right) when Type_shape.typ_is_iter left.note -> Some (right, left)
  | CatE (left, right) when Type_shape.typ_is_iter right.note -> Some (left, right)
  | ListE (head :: tail) ->
    Some (head, { exp with it = ListE tail })
  | OptE (Some head) -> Some (head, { exp with it = OptE None })
  | _ -> None

let closed_constructor_heads ctx heads =
  match List.map constructor_pattern heads |> all_some [] with
  | Some [] -> false
  | Some ((category, key, _, _) :: _ as patterns) ->
    if not (List.for_all (fun (category', key', _, _) ->
        category = category' && key = key') patterns)
    then false
    else
      (match Constructor_registry.family_coverage (Context.constructors ctx)
               ~source_category:category ~static_args_key:key with
      | Constructor_registry.Open _ -> false
      | Closed entries ->
        List.for_all (fun entry ->
          List.exists (fun (_, _, mixop, arity) ->
            Il.Eq.eq_mixop mixop entry.Constructor_registry.mixop
            && arity = entry.arity) patterns) entries)
  | None -> false
(* Each constructor head above is checked before the family witness is read;
   there is no partial list access in this certificate path. *)

let synchronized_partial_clauses ctx facts params clauses call_args =
  let actuals = call_args |> List.filter_map (fun arg ->
    match arg.it with ExpA exp -> Some exp | TypA _ | DefA _ | GramA _ -> None) in
  let tokens = List.mapi (fun index exp -> index, length_token facts exp) actuals in
  let sequence_indices = tokens |> List.filter_map (function
    | index, Some _ -> Some index | _, None -> None) in
  let sequence_tokens = tokens |> List.filter_map snd in
  let synchronized =
    match sequence_tokens with
    | token :: rest -> List.for_all (( = ) token) rest
    | [] -> false
  in
  let clauses = clauses |> List.filter_map (fun clause ->
    Option.map (fun patterns -> clause, patterns) (runtime_args params clause)) in
  let groups = contiguous_clause_groups clauses in
  let representatives =
    groups |> List.filter_map (function head :: _ -> Some head | [] -> None)
  in
  let at indices patterns predicate =
    List.for_all (fun index ->
      match nth_opt patterns index with
      | Some pattern -> predicate pattern
      | None -> false) indices in
  let outside_wild patterns =
    patterns |> List.mapi (fun index pattern ->
      List.mem index sequence_indices || wildcard_pattern pattern)
    |> List.for_all Fun.id in
  let bases, steps = representatives |> List.partition (fun (_, patterns) ->
    at sequence_indices patterns empty_sequence_pattern) in
  let step_heads = steps |> List.map (fun (clause, patterns) ->
    clause,
    List.map (fun index ->
      Option.bind (nth_opt patterns index) sequence_split) sequence_indices) in
  let all_steps = step_heads <> [] && List.for_all (fun (_, splits) ->
    List.for_all Option.is_some splits) step_heads
    && List.for_all (fun (_, patterns) -> outside_wild patterns) steps in
  let heads position = step_heads |> List.filter_map (fun (_, splits) ->
    Option.bind (nth_opt splits position) (Option.map fst)) in
  let positions = List.init (List.length sequence_indices) Fun.id in
  let wildcard_steps = positions |> List.for_all (fun position ->
    List.for_all wildcard_pattern (heads position)) in
  let discriminants = positions |> List.filter (fun position ->
    closed_constructor_heads ctx (heads position)) in
  let other_heads_wild position = positions |> List.for_all (fun other ->
    other = position || List.for_all wildcard_pattern (heads other)) in
  let covered_steps = wildcard_steps || List.exists other_heads_wild discriminants in
  let certified_groups =
    List.map (complete_clause_group ctx) groups |> all_some []
  in
  let complete_groups = Option.is_some certified_groups in
  let complete_bases = bases <> [] && List.for_all (fun (_, patterns) ->
    outside_wild patterns) bases in
  match synchronized, complete_bases, all_steps, covered_steps, complete_groups with
  | true, true, true, true, true -> Option.map List.concat certified_groups
  | _ -> None

let sequence_parameter_indices params clauses =
  let patterns = clauses |> List.filter_map (runtime_args params) in
  match patterns with
  | [] -> []
  | first :: _ ->
    List.init (List.length first) Fun.id |> List.filter (fun index ->
      List.for_all (fun patterns ->
        match nth_opt patterns index with
        | Some pattern ->
          empty_sequence_pattern pattern || Option.is_some (sequence_split pattern)
        | None -> false)
        patterns)

let implemented_total_builtin ctx id =
  match Builtin_registry.find (Context.builtins ctx) id with
  | Some entry ->
    entry.status = Builtin_registry.Implemented
    && not (Builtin_registry.declaration_is_partial (Context.builtins ctx) id)
  | None -> false

let conversion_preserves source target =
  match source, target with
  | `NatT, `NatT | `IntT, `IntT | `RatT, `RatT
  | `NatT, (`IntT | `RatT) | `IntT, `RatT -> true
  | `IntT, `NatT | (`NatT | `IntT), `RealT
  | (`RatT | `RealT), _ -> false

let rec strict_argument strict exp =
  match exp.it with
  | VarE id -> List.mem id.it strict
  | IterE ({ it = VarE body; _ },
           ((List | List1 | ListN _), [ generator, source ]))
    when body.it = generator.it -> strict_argument strict source
  | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner ->
    strict_argument strict inner
  | _ -> false

let certified_subtyping ctx source target =
  match
    Subtype_plan.make ~il_env:(Context.il_env ctx)
      ~source_index:(Context.source_index ctx)
      ~constructors:(Context.constructors ctx)
      ~static_typ_env:(Context.static_typ_env ctx) source target
  with
  | Ok (Subtype_plan.Identity | Injection _) -> true
  | Error _ -> false

let simple_struct_field ctx typ atom =
  let atom_info : Xl.Atom.info = atom.note in
  let type_id =
    if atom_info.def <> "" then Some atom_info.def else
    match typ.it with
    | VarT (id, []) -> Some id.it
    | VarT _ | BoolT | NumT _ | TextT | TupT _ | IterT _ -> None
  in
  let simple_field (_, (typ, binds, prems), _) =
    binds = [] && prems = [] && List.length (Type_shape.typ_components typ) = 1
  in
  match type_id with
  | None -> false
  | Some id ->
    (match
       Analysis.Source_index.find_by_id (Context.source_index ctx) id
       |> List.filter_map (fun entry ->
         match entry.Analysis.Source_index.def.it with
         | TypD (_, [], [ { it = InstD ([], [], { it = StructT fields; _ }); _ } ]) ->
           Some fields
         | TypD _ | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> None)
     with
    | [ fields ] ->
      List.for_all simple_field fields
      && List.exists (fun (field, _, _) -> Il.Eq.eq_atom field atom) fields
    | [] | _ :: _ :: _ -> false)

let tuple_projection_domain inner index =
  match inner.note.it with
  | TupT fields -> index >= 0 && index < List.length fields
  | VarT _ | BoolT | NumT _ | TextT | IterT _ -> false

let closed_singleton_constructor ctx constructor =
  match
    Constructor_registry.entries (Context.constructors ctx)
    |> List.filter (fun entry ->
      entry.Constructor_registry.status = Constructor_registry.Emitted
      && entry.constructor_op = constructor)
  with
  | [ entry ] ->
    (match
       Constructor_registry.family_coverage (Context.constructors ctx)
         ~source_category:entry.source_category
         ~static_args_key:entry.static_args_key
     with
    | Constructor_registry.Closed [ only ] ->
      only.Constructor_registry.constructor_op = constructor
    | Closed _ | Open _ -> false)
  | [] | _ :: _ :: _ -> false

let uncase_projection_domain ctx scrutinee mixop payload_typ index =
  let arity = List.length (Type_shape.typ_components payload_typ) in
  index >= 0 && index < arity
  && match
       Typcase_constructor.resolve_emitted ctx scrutinee.note mixop ~arity
     with
     | Typcase_constructor.Found resolution ->
       closed_singleton_constructor
         ctx resolution.Typcase_constructor.resolved_constructor
       && index < List.length resolution.projection_ops
     | Typcase_constructor.Missing
     | Typcase_constructor.Blocked _
     | Typcase_constructor.Ambiguous _ -> false

let total_unop = function
  | `NotOp, `BoolT
  | (`PlusOp | `MinusOp), (`IntT | `RatT | `RealT) -> true
  | (`NotOp | `PlusOp | `MinusOp), _ -> false

let total_binop = function
  | (`AndOp | `OrOp | `ImplOp | `EquivOp), `BoolT
  | (`AddOp | `MulOp), (`NatT | `IntT | `RatT | `RealT)
  | `SubOp, (`IntT | `RatT | `RealT) -> true
  | (`AndOp | `OrOp | `ImplOp | `EquivOp
    | `AddOp | `SubOp | `MulOp | `DivOp | `ModOp | `PowOp), _ -> false

let total_cmpop = function
  | (`EqOp | `NeOp), (`BoolT | `NatT | `IntT | `RatT | `RealT)
  | (`LtOp | `GtOp | `LeOp | `GeOp), (`NatT | `IntT | `RatT | `RealT) -> true
  | (`EqOp | `NeOp | `LtOp | `GtOp | `LeOp | `GeOp), _ -> false

let exact_total_constructor ctx typ mixop arity =
  match
    Subtype_plan.canonical_typ
      ~il_env:(Context.il_env ctx)
      ~static_typ_env:(Context.static_typ_env ctx)
      typ
  with
  | Error _ -> Error "constructor result type is not canonically reducible"
  | Ok typ ->
    let key_env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
    (match Static_key.typ_ref ~env:key_env typ with
    | None -> Error "constructor result type has no exact static category key"
    | Some { Static_key.category_id; static_args_key } ->
      let source_category = Naming.source_owner category_id in
      let certify_entry (entry : Constructor_registry.entry) =
        match entry.status with
        | Constructor_registry.Emitted -> Ok entry
        | Constructor_registry.Skipped | Constructor_registry.Unsupported ->
          Error
            ("exact constructor is "
             ^ Constructor_registry.status_to_string entry.status)
      in
      match
        Constructor_registry.lookup_visible
          (Context.constructors ctx)
          ~source_category
          ~static_args_key
          ~mixop
          ~arity
      with
      | Constructor_registry.Found entry -> certify_entry entry
      | Constructor_registry.Missing ->
        (match
           Typcase_constructor.resolve_emitted ctx typ mixop ~arity
         with
        | Typcase_constructor.Found resolution ->
          let entry = resolution.Typcase_constructor.registry_entry in
          if entry.arity <> arity
             || entry.constructor_op <> resolution.resolved_constructor
             || entry.projection_ops <> resolution.projection_ops
          then
            Error "resolved emitted constructor disagrees with its registry identity"
          else
            certify_entry entry
        | Typcase_constructor.Missing
        | Typcase_constructor.Blocked _
        | Typcase_constructor.Ambiguous _ ->
          Error
            "no emitted constructor has the exact category/static-key/mixop/arity identity")
      | Constructor_registry.Ambiguous _ ->
        Error "exact category/static-key/mixop/arity constructor identity is ambiguous")

let constructor_payload payload_index arg =
  let payloads =
    match arg.it with
    | TupE payloads -> payloads
    | _ -> [ arg ]
  in
  nth_opt payloads payload_index

let same_length_domain
    (left : Constructor_registry.entry)
    (right : Constructor_registry.entry) =
  left.source_category = right.source_category
  && left.static_args_key = right.static_args_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && left.constructor_op = right.constructor_op
  && left.projection_ops = right.projection_ops
  && match left.construction_domain, right.construction_domain with
     | Constructor_registry.Length_guarded_representation_constructor left,
       Constructor_registry.Length_guarded_representation_constructor right ->
       left.payload_index = right.payload_index
       && Il.Eq.eq_exp left.closed_bound right.closed_bound
       && left.guard_origin = right.guard_origin
     | _ -> false

let add_length_domain token entry facts =
  if
    List.exists
      (fun (token', entry') ->
        token = token' && same_length_domain entry entry')
      facts.length_domains
  then
    facts
  else
    { facts with length_domains = (token, entry) :: facts.length_domains }

let pattern_length_token facts pattern =
  match length_token facts pattern with
  | Some token -> token
  | None ->
    "pattern:"
    ^ Digest.to_hex
        (Digest.string
           (Il.Print.string_of_exp pattern
            ^ ":" ^ Il.Print.string_of_typ pattern.note))

let rec add_pattern_length_domains ctx facts pattern =
  let recurse = add_pattern_length_domains ctx in
  let recurse_many = List.fold_left recurse in
  match pattern.it with
  | CaseE (mixop, arg) ->
    let facts = recurse facts arg in
    let arity =
      match arg.it with
      | TupE payloads -> List.length payloads
      | _ -> 1
    in
    (match exact_total_constructor ctx pattern.note mixop arity with
    | Ok ({ construction_domain =
              Constructor_registry.Length_guarded_representation_constructor
                certificate; _ } as entry) ->
      (match constructor_payload certificate.payload_index arg with
      | Some payload when Type_shape.typ_is_iter payload.note ->
        let token = pattern_length_token facts payload in
        let facts = bind_pattern_facts (Some token) facts payload in
        add_length_domain token entry facts
      | Some _ | None -> facts)
    | Ok _ | Error _ -> facts)
  | TupE patterns | ListE patterns -> recurse_many facts patterns
  | OptE (Some pattern) | LiftE pattern
  | CvtE (pattern, _, _) | SubE (pattern, _, _) -> recurse facts pattern
  | CatE (left, right) -> recurse (recurse facts left) right
  | StrE fields ->
    fields |> List.map snd |> recurse_many facts
  | IterE (body, (_, generators)) ->
    let facts = recurse facts body in
    generators |> List.map snd |> recurse_many facts
  | VarE _ | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _
  | ProjE _ | UncaseE _ | OptE None | TheE _ | DotE _ | CompE _
  | MemE _ | LenE _ | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _
  | CallE _ -> facts

(* Evaluating IterE(body, (List, [x, source])) emits exactly one body result
   for each source element.  Its output length therefore equals the source
   length, so the same closed upper bound remains valid. *)
let preserves_length_domain facts entry arg =
  match entry.Constructor_registry.construction_domain with
  | Constructor_registry.Length_guarded_representation_constructor certificate ->
    let certified_source source =
      match length_token facts source with
      | Some token ->
        List.exists
          (fun (token', source_entry) ->
            token = token' && same_length_domain entry source_entry)
          facts.length_domains
      | None -> false
    in
    (match constructor_payload certificate.payload_index arg with
    | Some { it = IterE (_, (List, [ _, source ])); _ } ->
      certified_source source
    | Some { it = IterE (_, (ListN (count, _), [ _, source ])); _ } ->
      (match count_token facts count, length_token facts source with
      | Some count_token, Some source_token when count_token = source_token ->
        certified_source source
      | Some _, Some _ | None, _ | _, None -> false)
    | Some _ | None -> false)
  | Constructor_registry.Total_constructor
  | Constructor_registry.Certified_representation_constructor
  | Constructor_registry.Guarded_constructor _ -> false

let facts_with_domain total_facts =
  { empty_facts with validated_sequence_indices = total_facts }

let validated_sequence_index facts exp =
  facts.validated_sequence_indices
  |> List.find_opt (function
    | Runtime_truth_successor_domain.Validated_sequence_index { witness; _ } ->
      Il.Eq.eq_exp witness exp)

let exact_singleton_constructor ctx pattern =
  let rec unwrap exp =
    match exp.it with
    | SubE (inner, _, _) | CvtE (inner, _, _) | LiftE inner -> unwrap inner
    | _ -> exp
  in
  let pattern = unwrap pattern in
  match pattern.it with
  | CaseE (mixop, payload) ->
    let arity = match payload.it with TupE exps -> List.length exps | _ -> 1 in
    (match exact_total_constructor ctx pattern.note mixop arity with
    | Ok entry ->
      (match
         Constructor_registry.family_coverage (Context.constructors ctx)
           ~source_category:entry.source_category
           ~static_args_key:entry.static_args_key
       with
      | Constructor_registry.Closed [ only ] ->
        only.Constructor_registry.constructor_op = entry.constructor_op
      | Closed _ | Open _ -> false)
    | Error _ -> false)
  | _ -> false

let validated_partial_clauses ctx facts params clauses call_args =
  let actuals =
    call_args |> List.filter_map (fun arg ->
      match arg.it with ExpA exp -> Some exp | TypA _ | DefA _ | GramA _ -> None)
  in
  match clauses, actuals with
  | [ clause ], [ actual ]
    when Option.is_some (validated_sequence_index facts actual) ->
    (match runtime_args params clause with
    | Some [ pattern ] when exact_singleton_constructor ctx pattern ->
      Some [ { clause; patterns = [ pattern ]; allow_else = false } ]
    | Some _ | None -> None)
  | _ -> None

let rec direct_var = function
  | { it = VarE id; _ } -> Some id.it
  | { it = IterE ({ it = VarE body; _ },
                  ((List | List1 | ListN _), [ generator, source ])); _ }
    when String.equal body.it generator.it ->
    direct_var source
  | { it = SubE (inner, _, _) | CvtE (inner, _, _); _ } -> direct_var inner
  | _ -> None

let indexed_rhs = function
  | { it = IdxE (base, index); _ } ->
    Option.map (fun index_id -> base, index_id) (direct_var index)
  | _ -> None

let add_validated_index_facts ctx inherited_facts actuals patterns clause =
  match actuals, patterns, clause.it with
  | [ actual ], [ pattern ], DefD (_, _, rhs, _)
    when exact_singleton_constructor ctx pattern ->
    (match validated_sequence_index inherited_facts actual, indexed_rhs rhs with
    | Some (Runtime_truth_successor_domain.Validated_sequence_index
              { source; index_source_id; _ }),
      Some (base, index_id) ->
      let input_ids = pattern_ids pattern in
      if String.equal index_id index_source_id
         && List.mem index_id input_ids
         && Il.Eq.eq_exp base source
      then
        (match direct_var base with
        | Some base_id ->
          { inherited_facts with
            defined_indices =
              (base_id, index_id) :: inherited_facts.defined_indices
          }
        | None -> inherited_facts)
      else inherited_facts
    | Some _, None | None, _ -> inherited_facts)
  | _ -> inherited_facts

let rec total_exp
    ctx visited strict bound facts origin exp =
  let recurse =
    total_exp ctx visited strict bound facts origin
  in
  match exp.it with
  | VarE id ->
    if List.mem id.it bound then Total
    else Blocked [ blocker origin exp "unbound" "source variable is not bound by the certified clause" ]
  | BoolE _ | NumE _ | TextE _ -> Total
  | UnE (op, typ, inner) when total_unop (op, typ) -> recurse inner
  | UnE _ -> Blocked [ blocker origin exp "partial-operator"
      "the annotated unary operator has no structurally total SpecTec evaluation domain" ]
  | BinE (op, typ, left, right) when total_binop (op, typ) ->
    combine [ recurse left; recurse right ]
  | BinE _ -> Blocked [ blocker origin exp "partial-operator"
      "division, modulo, exponentiation, natural subtraction, or a malformed annotated binary operator requires an explicit source-domain proof" ]
  | CmpE (op, typ, left, right) when total_cmpop (op, typ) ->
    combine [ recurse left; recurse right ]
  | CmpE _ -> Blocked [ blocker origin exp "partial-operator"
      "the annotated comparison operator has no structurally total SpecTec evaluation domain" ]
  | ProjE ({ it = UncaseE (scrutinee, mixop); note = payload_typ; _ }, index)
    when uncase_projection_domain ctx scrutinee mixop payload_typ index ->
    recurse scrutinee
  | ProjE (inner, index) when tuple_projection_domain inner index -> recurse inner
  | UncaseE (scrutinee, mixop)
    when uncase_projection_domain ctx scrutinee mixop exp.note 0 ->
    recurse scrutinee
  | DotE (inner, atom) when simple_struct_field ctx inner.note atom -> recurse inner
  | ProjE _ | UncaseE _ | DotE _ ->
    Blocked [ blocker origin exp "partial-destructor"
      "projection, constructor destruction, and record field selection require an explicit structural domain certificate" ]
  | LenE exp | LiftE exp -> recurse exp
  | CompE (left, right) | CatE (left, right) -> combine [ recurse left; recurse right ]
  | TupE exps | ListE exps -> combine (List.map recurse exps)
  | OptE None -> Total
  | OptE (Some exp) -> recurse exp
  | CaseE (mixop, arg) ->
    let arity =
      match arg.it with TupE exps -> List.length exps | _ -> 1
    in
    (match exact_total_constructor ctx exp.note mixop arity with
    | Ok ({ construction_domain =
              (Constructor_registry.Total_constructor
              | Constructor_registry.Certified_representation_constructor); _ }) ->
      recurse arg
    | Ok ({ construction_domain =
              Constructor_registry.Length_guarded_representation_constructor _; _ }
            as entry)
      when preserves_length_domain facts entry arg ->
      recurse arg
    | Ok { construction_domain =
             Constructor_registry.Length_guarded_representation_constructor _; _ } ->
      Blocked [ blocker origin exp "constructor-domain"
        "the exact source constructor has a length premise, but its payload is not a single-generator List IterE over a source pattern carrying the same exact length-domain certificate; Opt, List1, ListN, zero/multiple generators, and cardinality-changing shapes remain blocked" ]
    | Ok { construction_domain = Constructor_registry.Guarded_constructor reason; _ } ->
      Blocked [ blocker origin exp "constructor-domain"
        ("exact constructor source domain is guarded: " ^ reason) ]
    | Error reason ->
      Blocked [ blocker origin exp "constructor-domain"
        reason ])
  | StrE fields -> combine (fields |> List.map (fun (_, exp) -> recurse exp))
  | IfE (cond, left, right) -> combine [ recurse cond; recurse left; recurse right ]
  | CallE (id, args) ->
    total_call
      ctx visited strict bound facts origin exp id args
  | IterE (body, (iter, generators)) ->
    let sources = generators |> List.map (fun (_, source) -> recurse source) in
    let sources, iter_ids = match iter with
      | ListN (count, Some id) -> recurse count :: sources, [ id.it ]
      | ListN (count, None) -> recurse count :: sources, []
      | Opt | List | List1 -> sources, [] in
    let body_bound = add_ids
        (iter_ids @ List.map (fun (id, _) -> id.it) generators) bound in
    (match
       combine
         (total_exp
            ctx visited strict body_bound facts origin body
          :: sources)
     with
    | Blocked _ as blocked -> blocked
    | Total
      when iteration_domain_is_structural facts iter generators
           || indexed_enumeration_domain facts iter generators ->
      Total
    | Total ->
      Blocked
        [ blocker origin exp "iteration-domain"
            "IterE lacks the evaluator domain proof required by its iterator: generators must be nonempty; List/List1 lengths synchronized; List1 nonempty; Opt presence synchronized; and ListN count defined with every generator length equal to it"
        ])
  | IdxE (base, index) ->
    (match direct_var base, direct_var index with
    | Some base_id, Some index_id
      when List.mem (base_id, index_id) facts.defined_indices ->
      combine [ recurse base; recurse index ]
    | _ ->
      Blocked
        [ blocker origin exp "index-domain"
            "IdxE has no exact call-site definedness certificate for this sequence/index pair"
        ])
  | SubE (inner, source, target) when certified_subtyping ctx source target -> recurse inner
  | CvtE (inner, source, target) when conversion_preserves source target -> recurse inner
  | TheE _ | MemE _ | SliceE _ | UpdE _ | ExtE _ | SubE _ | CvtE _ ->
    Blocked [ blocker origin exp "partial-constructor"
      "this expression may be undefined and has no totality contract for false refutation" ]

and total_arg ctx visited strict bound facts origin arg =
  match arg.it with
  | ExpA exp ->
    total_exp ctx visited strict bound facts origin exp
  | TypA _ -> Total
  | DefA _ | GramA _ ->
    Blocked [ { origin; constructor = "RuntimeTruthTotalEquality/Arg/static-call"
      ; reason = "definition/grammar-valued arguments require exact specialization totality"
      ; source_echo = Some (Il.Print.string_of_arg arg) } ]

and total_call ctx visited strict bound facts origin exp id args =
  let target = Option.value ~default:id.it (Context.find_static_def ctx id.it) in
  match
    combine
      (List.map
         (total_arg ctx visited strict bound facts origin)
         args)
  with
  | Blocked _ as blocked -> blocked
  | Total when List.mem target visited ->
    let decreases_by = args |> List.filter_map (fun arg ->
      match arg.it with ExpA exp -> Some (strict_argument strict exp) | _ -> None) in
    let decreases = List.exists Fun.id decreases_by in
    let runtime_exps = args |> List.filter_map (fun arg ->
      match arg.it with ExpA exp -> Some exp | TypA _ | DefA _ | GramA _ -> None) in
    let sequence_tokens =
      match definition_entry ctx target with
      | Some (params, clauses) ->
        sequence_parameter_indices params clauses |> List.filter_map (fun index ->
          Option.bind (nth_opt runtime_exps index) (length_token facts))
      | None -> [] in
    let recursive_domain =
      match Analysis.Function_graph.find_definition (Context.function_graph ctx) target with
      | Some definition when definition.partial ->
        (match sequence_tokens with
        | token :: rest -> List.for_all (( = ) token) rest
        | [] -> false)
      | Some _ | None -> true
    in
    if decreases && recursive_domain then Total
    else Blocked [ blocker origin exp "recursive-call"
      ("definition `" ^ target
       ^ "` recurs without a certified strict source subterm in its covered domain"
       ^ "; strict variables=" ^ String.concat "," strict
       ^ "; decreasing arguments="
       ^ String.concat "," (List.map string_of_bool decreases_by)
       ^ "; sequence domains=" ^ String.concat "," sequence_tokens) ]
  | Total ->
    let graph = Context.function_graph ctx in
    let resolution = Analysis.Function_graph.resolve_call graph
        ~static_typ_env:(Context.static_typ_env ctx)
        ~static_def_env:(Context.static_def_env ctx) ~origin id args in
    let identity = match resolution with
      | Analysis.Function_graph.Plain_call -> Some (Analysis.Function_graph.plain_identity target)
      | Specialized_call specialization -> Some (Analysis.Function_graph.identity_of_specialization specialization)
      | Unsupported_call _ | Prelude_gap_call _ -> None in
    (match identity with
    | None -> Blocked [ blocker origin exp "unresolved-call"
        ("CallE target `" ^ target ^ "` has no structured emitted definition identity") ]
    | Some identity when Analysis.Function_graph.identity_is_rewrite_backed graph identity ->
      Blocked [ blocker origin exp "rewrite-backed-call"
        ("CallE target `" ^ target ^ "` evaluates by rewriting") ]
    | Some _ when implemented_total_builtin ctx target -> Total
    | Some _ ->
      total_definition
        ctx (target :: visited) facts origin exp target args)

and total_definition ctx visited facts origin call_exp target call_args =
  let graph = Context.function_graph ctx in
  match Analysis.Function_graph.find_definition graph target, definition_entry ctx target with
  | Some definition, _ when definition.clause_count = 0 ->
    Blocked [ blocker origin call_exp "clause-free-call"
      ("CallE target `" ^ target ^ "` has no source clause and no implemented total backend contract") ]
  | Some _, Some (params, clauses) ->
    let coverage =
      match Analysis.Function_graph.find_definition graph target with
      | Some definition when definition.partial ->
        (match synchronized_partial_clauses ctx facts params clauses call_args with
        | Some _ as coverage -> coverage
        | None -> validated_partial_clauses ctx facts params clauses call_args)
      | Some _ ->
        (match source_complete_clauses ctx params clauses with
        | Some _ as coverage -> coverage
        | None -> validated_partial_clauses ctx facts params clauses call_args)
      | None -> None
    in
    (match coverage with
    | None -> Blocked [ blocker origin call_exp "open-clause-domain"
        ("CallE target `" ^ target
         ^ "` clauses do not structurally cover its source domain; clause patterns: "
         ^ clause_shapes params clauses) ]
    | Some clauses ->
      let actuals = call_args |> List.filter_map (fun arg ->
        match arg.it with ExpA exp -> Some exp | TypA _ | DefA _ | GramA _ -> None) in
      combine
        (List.map
           (total_clause ctx visited facts origin actuals)
           clauses))
  | None, _ | Some _, None ->
    Blocked [ blocker origin call_exp "missing-declaration"
      ("CallE target `" ^ target ^ "` has no unique DecD source declaration") ]

and total_clause ctx visited inherited_facts origin actuals covered =
  let clause = covered.clause and patterns = covered.patterns in
  match clause.it with
  | DefD (_, _, rhs, prems) ->
    let bound = patterns |> List.concat_map pattern_ids in
    let facts =
      if List.length actuals = List.length patterns then
        List.fold_left2 (fun facts actual pattern ->
          bind_pattern_facts (length_token inherited_facts actual) facts pattern)
          inherited_facts actuals patterns
      else inherited_facts
    in
    let facts =
      List.fold_left (add_pattern_length_domains ctx) facts patterns
    in
    let facts =
      add_validated_index_facts ctx inherited_facts actuals patterns clause
      |> fun validated ->
      { facts with defined_indices = validated.defined_indices }
    in
    let facts =
      match List.filter_map sequence_split patterns with
      | _ :: _ as splits ->
        let token = "tail:" ^ Origin.summary origin ^ ":"
          ^ Util.Source.string_of_region clause.at in
        splits |> List.fold_left (fun facts split ->
          let _, tail = split in
          bind_pattern_facts (Some token) facts tail) facts
      | _ -> facts
    in
    let strict =
      patterns |> List.filter_map sequence_split
      |> List.concat_map (fun (_, tail) -> pattern_ids tail)
    in
    let premises, bound, facts =
      total_premises
        ctx visited strict bound facts origin covered.allow_else prems
    in
    (match premises with
    | Blocked _ as blocked -> blocked
    | Total ->
      total_exp ctx visited strict bound facts origin rhs)

and total_premises ctx visited strict bound facts origin allow_else = function
  | [] -> Total, bound, facts
  | prem :: rest ->
    let bind left right =
      let fresh = pattern_ids left |> List.filter (fun id -> not (List.mem id bound)) in
      if fresh = [] || not (certified_binding_pattern ctx bound left) then
        (Blocked [ blocker origin left "non-binding-premise"
          "a source condition is not an irrefutable fresh binding and therefore cannot certify total clause coverage" ], bound, facts)
      else
        match
          total_exp ctx visited strict bound facts origin right
        with
        | Blocked _ as blocked -> blocked, bound, facts
        | Total ->
          let bound = add_ids fresh bound in
          let facts = bind_pattern_facts (length_token facts right) facts left in
          let facts = add_pattern_length_domains ctx facts left in
          total_premises
            ctx visited strict bound facts origin allow_else rest
    in
    match prem.it with
    | IfPr ({ it = CmpE (`EqOp, _, left, right); _ } as condition) ->
      let bindable pattern =
        let fresh =
          pattern_ids pattern |> List.filter (fun id -> not (List.mem id bound))
        in
        fresh <> [] && certified_binding_pattern ctx bound pattern
      in
      if bindable left then bind left right
      else if bindable right then bind right left
      else
        (match
           total_exp ctx visited strict bound facts origin condition
         with
        | Blocked _ as blocked -> blocked, bound, facts
        | Total ->
          total_premises
            ctx visited strict bound facts origin allow_else rest)
    | LetPr (_, left, right) -> bind left right
    | ElsePr when allow_else ->
      total_premises
        ctx visited strict bound facts origin false rest
    | ElsePr ->
      (Blocked [ premise_blocker origin prem "uncertified-else"
        "ElsePr is total only inside a certified source-ordered guard/fallback partition" ],
       bound, facts)
    | IfPr _ | RulePr _ | IterPr _ | NegPr _ ->
      (Blocked [ { origin; constructor = "RuntimeTruthTotalEquality/Premise/non-total"
        ; reason = "source clause coverage depends on a premise that is not a total binding"
        ; source_echo = Some (Il.Print.string_of_prem prem) } ], bound, facts)

let source_bound_vars ?bound_vars env exp =
  let maude_bound =
    Option.value ~default:(Expr_env.bound_vars env) bound_vars
  in
  Source_free_vars.exp_and_note_ids exp
  |> List.filter (fun id ->
      match Expr_env.find env id with
      | None -> false
      | Some binding ->
        Condition_closure.term_vars binding.Expr_env.term
        |> List.for_all (fun var -> List.mem var maude_bound))

let total_exp_with_extra_bound
    ?bound_vars ?(domain_facts = []) ctx env origin extra_bound exp =
  let bound = add_ids extra_bound (source_bound_vars ?bound_vars env exp) in
  let facts = facts_with_domain domain_facts in
  total_exp ctx [] [] bound facts origin exp

let total_exp ?bound_vars ctx env origin exp =
  total_exp_with_extra_bound ?bound_vars ctx env origin [] exp

let source_total ?(facts = []) ctx ~bound origin exp =
  match
    total_exp_with_extra_bound ~domain_facts:facts
      ctx Expr_env.empty origin bound exp
  with
  | Total -> true
  | Blocked _ -> false

let diagnostic ctx blocker =
  Diagnostics.make ~category:Diagnostics.Unsupported ~origin:blocker.origin
    ~constructor:blocker.constructor
    ~enclosing:(Diagnostic_provenance.enclosing ~context:(Context.enclosing_path ctx) blocker.origin)
    ~profile:(Context.profile_name ctx) ~reason:blocker.reason
    ~suggestion:"Keep this false edge Unsupported until evaluation is structurally total; a stuck call must not satisfy inequality"
    ?source_echo:blocker.source_echo ()

let false_conditions ?bound_vars ctx env origin op left_exp right_exp =
  match
    total_exp ?bound_vars ctx env origin left_exp,
    total_exp ?bound_vars ctx env origin right_exp
  with
  | Total, Total ->
    let left = Expr_translate.lower_value ctx env origin left_exp in
    let right = Expr_translate.lower_value ctx env origin right_exp in
    (match left.term, right.term, op with
    | Some left_term, Some right_term, (`EqOp | `NeOp) ->
      let false_op = if op = `EqOp then "_=/=_" else "_==_" in
      Ok (left.guards @ right.guards
          @ [ Maude_ir.BoolCond (Maude_ir.App (false_op, [ left_term; right_term ])) ],
          left.diagnostics @ right.diagnostics)
    | _ -> Error [ blocker origin left_exp "lowering"
        "certified operand did not lower to an equality-comparable Maude term" ])
  | left, right -> Error (List.concat_map (function Total -> [] | Blocked bs -> bs) [ left; right ])

let index_domain_blocker origin exp reason =
  blocker origin exp "index-domain" reason

let result_has_fatal (result : Expr_result.result) =
  List.exists Diagnostics.is_fatal result.diagnostics

let merge_domain_results results =
  let rec merge domains guards diagnostics blockers = function
    | [] ->
      if blockers = [] then
        Ok (List.rev domains |> List.concat,
            List.rev guards |> List.concat,
            List.rev diagnostics |> List.concat)
      else
        Error (List.rev blockers |> List.concat)
    | Ok (next_domains, next_guards, next_diagnostics) :: rest ->
      merge
        (next_domains :: domains)
        (next_guards :: guards)
        (next_diagnostics :: diagnostics)
        blockers rest
    | Error next_blockers :: rest ->
      merge domains guards diagnostics (next_blockers :: blockers) rest
  in
  merge [] [] [] [] results

let length_term term = Maude_ir.App ("len", [ term ])

let synchronized_length_domains terms =
  match terms with
  | [] | [ _ ] -> []
  | first :: rest ->
    rest
    |> List.filter_map (fun term ->
      if term = first then None
      else
        Some
          (Maude_ir.App
             ("_==_", [ length_term first; length_term term ])))

let iteration_domain_terms iter first_source source_terms count_term =
  match source_terms with
  | [] -> None
  | first_term :: _ ->
    let synchronized = synchronized_length_domains source_terms in
    match iter, count_term with
    | List, None | Opt, None -> Some synchronized
    | List1, None ->
      let nonempty =
        if structurally_nonempty empty_facts first_source then []
        else
          [ Maude_ir.App
              ("_>_", [ length_term first_term; Maude_ir.Const "0" ]) ]
      in
      Some (nonempty @ synchronized)
    | ListN _, Some count ->
      Some
        (List.map
           (fun source ->
             Maude_ir.App ("_==_", [ length_term source; count ]))
           source_terms)
    | (List | List1 | Opt), Some _ | ListN _, None -> None

let bool_domain_terms conditions =
  let rec collect acc = function
    | [] -> Some (List.rev acc)
    | Maude_ir.BoolCond term :: rest -> collect (term :: acc) rest
    | (Maude_ir.EqCond _ | Maude_ir.MatchCond _
      | Maude_ir.MembershipCond _) :: _ -> None
  in
  collect [] conditions

let bool_fold op = function
  | [] -> None
  | first :: rest ->
    Some (List.fold_left (fun left right -> Maude_ir.App (op, [ left; right ])) first rest)

let subtype_pattern_domain ctx env origin actual pattern =
  match pattern.it with
  | SubE ({ it = VarE _; _ }, source, _) ->
    let actual_result = Expr_translate.lower_value ctx env origin actual in
    let witness_result =
      Expr_translate.lower_type_witness
        ctx env origin ~constructor:"RuntimeTruthTotalEquality/CallE/domain" source
    in
    (match
       actual_result.term,
       witness_result.term,
       Expr_translate.carrier_sort_of_typ source
     with
    | Some actual, Some witness, Some sort
      when actual_result.guards = [] && witness_result.guards = []
           && not (result_has_fatal actual_result)
           && not (result_has_fatal witness_result) ->
      let conditions =
        Expr_translate.typecheck_conditions_for_typ
          source sort actual witness
      in
      Option.map
        (fun terms ->
          terms,
          actual_result.diagnostics @ witness_result.diagnostics)
        (bool_domain_terms conditions)
    | _ -> None)
  | _ -> None

let partial_call_domain ctx env origin target params clauses call_args =
  let actuals =
    call_args
    |> List.filter_map (fun arg ->
      match arg.it with
      | ExpA exp -> Some exp
      | TypA _ | DefA _ | GramA _ -> None)
  in
  let clause_domain clause =
    match clause.it, runtime_args params clause with
    | DefD (_, _, _, []), Some patterns
      when patterns <> [] && List.length patterns = List.length actuals ->
      let pattern_domains =
        List.map2 (subtype_pattern_domain ctx env origin) actuals patterns
        |> all_some []
      in
      (match pattern_domains with
      | None -> None
      | Some pattern_domains ->
        let terms = List.concat_map fst pattern_domains in
        let diagnostics = List.concat_map snd pattern_domains in
        let covered = { clause; patterns; allow_else = false } in
        (match
           total_clause ctx [ target ] empty_facts origin actuals covered
         with
        | Total ->
          Option.map (fun domain -> domain, diagnostics)
            (bool_fold "_and_" terms)
        | Blocked _ -> None))
    | DefD _, _ -> None
  in
  if clauses = [] then None else
  match List.map clause_domain clauses |> all_some [] with
  | None -> None
  | Some clauses ->
    let domains = List.map fst clauses in
    let diagnostics = List.concat_map snd clauses in
    Option.map (fun domain -> domain, diagnostics)
      (bool_fold "_or_" domains)

let direct_call_substitution params clause call_args =
  match clause.it with
  | DefD (_, _, rhs, []) ->
    let patterns = runtime_args params clause in
    let actuals =
      call_args
      |> List.filter_map (fun arg ->
        match arg.it with
        | ExpA exp -> Some exp
        | TypA _ | DefA _ | GramA _ -> None)
    in
    (match patterns with
    | Some patterns when List.length patterns = List.length actuals ->
      let subst =
        List.fold_left2
          (fun subst pattern actual ->
            match subst, pattern.it with
            | Some subst, VarE id -> Some (Il.Subst.add_varid subst id actual)
            | Some _, _ | None, _ -> None)
          (Some Il.Subst.empty) patterns actuals
      in
      Option.map (fun subst -> Il.Subst.subst_exp subst rhs) subst
    | Some _ | None -> None)
  | DefD (_, _, _, _ :: _) -> None

let rec index_domains ?bound_vars ?(visited = []) ctx env origin exp =
  let recurse = index_domains ?bound_vars ~visited ctx env origin in
  match exp.it with
  | UnE (op, typ, inner) when total_unop (op, typ) -> recurse inner
  | BinE (op, typ, left, right) when total_binop (op, typ) ->
    merge_domain_results [ recurse left; recurse right ]
  | CmpE (op, typ, left, right) when total_cmpop (op, typ) ->
    merge_domain_results [ recurse left; recurse right ]
  | CompE (left, right) | CatE (left, right) ->
    merge_domain_results [ recurse left; recurse right ]
  | TupE exps | ListE exps ->
    merge_domain_results (List.map recurse exps)
  | OptE None -> Ok ([], [], [])
  | OptE (Some inner) -> recurse inner
  | StrE fields ->
    merge_domain_results (List.map (fun (_, field) -> recurse field) fields)
  | IfE (condition, yes, no) ->
    merge_domain_results [ recurse condition; recurse yes; recurse no ]
  | IterE (body, (iter, ((_, first_source) :: _ as generators))) ->
    let sources = List.map snd generators in
    let nested = List.map recurse sources in
    let nested =
      match iter with
      | ListN (count, _) -> recurse count :: nested
      | Opt | List | List1 -> nested
    in
    (match merge_domain_results nested with
    | Error blockers -> Error blockers
    | Ok (nested_domains, nested_guards, nested_diagnostics) ->
      let body_bound =
        List.map (fun (id, _) -> id.it) generators
        @ match iter with
          | ListN (_, Some id) -> [ id.it ]
          | ListN (_, None) | Opt | List | List1 -> []
      in
      (match
         total_exp_with_extra_bound
           ?bound_vars ctx env origin body_bound body
       with
      | Blocked blockers -> Error blockers
      | Total ->
        let lowered_sources =
          List.map (Expr_translate.lower_sequence ctx env origin) sources
        in
        let source_terms =
          lowered_sources
          |> List.map (fun (result : Expr_result.result) -> result.term)
          |> all_some []
        in
        let source_diagnostics =
          List.concat_map
            (fun (result : Expr_result.result) -> result.diagnostics)
            lowered_sources
        in
        if Option.is_none source_terms
           || List.exists result_has_fatal lowered_sources
        then
          Error
            [ blocker origin exp "iteration-domain"
                "IterE generator source did not lower to a total sequence term"
            ]
        else match source_terms with
        | None ->
          Error
            [ blocker origin exp "iteration-domain"
                "IterE generator source terms disappeared after successful lowering"
            ]
        | Some source_terms ->
          let count_term, count_guards, count_diagnostics =
            match iter with
            | ListN (count, _) when count.note.it = NumT `NatT ->
              let lowered = Expr_translate.lower_value ctx env origin count in
              lowered.term, lowered.guards, lowered.diagnostics
            | ListN _ -> None, [], []
            | Opt | List | List1 -> None, [], []
          in
          let count_term =
            match iter with
            | ListN _ -> count_term
            | Opt | List | List1 -> None
          in
          (match
             iteration_domain_terms
               iter first_source source_terms count_term
           with
          | None ->
            Error
              [ blocker origin exp "iteration-domain"
                  "ListN count is not a defined Nat term, or the iterator/count shape is inconsistent"
              ]
          | Some domains ->
            Ok
              ( nested_domains @ domains
              , nested_guards
                @ List.concat_map
                    (fun (result : Expr_result.result) -> result.guards)
                    lowered_sources
                @ count_guards
              , nested_diagnostics @ source_diagnostics @ count_diagnostics ))))
  | IterE (_, (_, [])) ->
    Error
      [ blocker origin exp "iteration-domain"
          "zero-generator IterE has no certified evaluator domain"
      ]
  | IdxE (base, index) ->
    (match recurse base, recurse index with
    | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
    | Error left, Error right -> Error (left @ right)
    | Ok (base_domains, base_guards, base_diagnostics),
      Ok (index_domains, index_guards, index_diagnostics) ->
      let base_result = Expr_translate.lower_sequence ctx env origin base in
      let index_result = Expr_translate.lower_value ctx env origin index in
      (match base_result.term, index_result.term with
      | Some base_term, Some index_term
        when not (result_has_fatal base_result)
             && not (result_has_fatal index_result) ->
        Ok
          ( base_domains @ index_domains
            @ [ Maude_ir.App ("indexDefined", [ base_term; index_term ]) ]
          , base_guards @ index_guards
            @ base_result.guards @ index_result.guards
          , base_diagnostics @ index_diagnostics
            @ base_result.diagnostics @ index_result.diagnostics )
      | _ ->
        Error
          [ index_domain_blocker origin exp
              "IdxE definedness requires structurally total sequence and Nat operands with emitted Maude terms"
          ]))
  | CallE (id, args) ->
    let target = Option.value ~default:id.it (Context.find_static_def ctx id.it) in
    let argument_domains =
      args
      |> List.filter_map (fun arg ->
        match arg.it with
        | ExpA exp -> Some (recurse exp)
        | TypA _ | DefA _ | GramA _ -> None)
    in
    (match merge_domain_results argument_domains with
    | Error blockers -> Error blockers
    | Ok (domains, guards, diagnostics) ->
      if List.mem target visited then
        Error
          [ blocker origin exp "recursive-domain-call"
              ("CallE target `" ^ target
               ^ "` recurs while deriving its source definedness domain")
          ]
      else
        let graph = Context.function_graph ctx in
        let resolution =
          Analysis.Function_graph.resolve_call graph
            ~static_typ_env:(Context.static_typ_env ctx)
            ~static_def_env:(Context.static_def_env ctx)
            ~origin id args
        in
        let identity =
          match resolution with
          | Analysis.Function_graph.Plain_call ->
            Some (Analysis.Function_graph.plain_identity target)
          | Specialized_call specialization ->
            Some (Analysis.Function_graph.identity_of_specialization specialization)
          | Unsupported_call _ | Prelude_gap_call _ -> None
        in
        match identity with
        | Some identity
          when not (Analysis.Function_graph.identity_is_rewrite_backed graph identity)
               && implemented_total_builtin ctx target ->
          Ok (domains, guards, diagnostics)
        | Some identity
          when not (Analysis.Function_graph.identity_is_rewrite_backed graph identity) ->
          (match definition_entry ctx target with
          | Some (params, [ clause ]) ->
            (match direct_call_substitution params clause args with
            | Some rhs ->
              (match
                 index_domains ?bound_vars ~visited:(target :: visited)
                   ctx env origin rhs
               with
              | Error blockers -> Error blockers
              | Ok (rhs_domains, rhs_guards, rhs_diagnostics) ->
                Ok
                  ( domains @ rhs_domains
                  , guards @ rhs_guards
                  , diagnostics @ rhs_diagnostics ))
            | None ->
              (match total_exp ?bound_vars ctx env origin exp with
              | Total -> Ok (domains, guards, diagnostics)
              | Blocked blockers -> Error blockers))
          | Some (params, clauses) ->
            (match
               partial_call_domain
                 ctx env origin target params clauses args
             with
            | Some (domain, domain_diagnostics) ->
              Ok
                ( domains @ [ domain ]
                , guards
                , diagnostics @ domain_diagnostics )
            | None ->
              (match total_exp ?bound_vars ctx env origin exp with
              | Total -> Ok (domains, guards, diagnostics)
              | Blocked blockers -> Error blockers))
          | None ->
            (match total_exp ?bound_vars ctx env origin exp with
            | Total -> Ok (domains, guards, diagnostics)
            | Blocked blockers -> Error blockers))
        | None | Some _ ->
          (match total_exp ?bound_vars ctx env origin exp with
          | Total -> Ok (domains, guards, diagnostics)
          | Blocked blockers -> Error blockers))
  | CvtE (inner, source, target) ->
    (match recurse inner with
    | Error blockers -> Error blockers
    | Ok (domains, guards, diagnostics) when conversion_preserves source target ->
      Ok (domains, guards, diagnostics)
    | Ok (domains, guards, diagnostics) ->
      let lowered = Expr_translate.lower_value ctx env origin exp in
      (match lowered.term, bool_domain_terms lowered.guards with
      | Some _, Some (_ :: _ as conversion_domains)
        when not (result_has_fatal lowered) ->
        Ok
          ( domains @ conversion_domains
          , guards
          , diagnostics @ lowered.diagnostics )
      | _ ->
        Error
          [ blocker origin exp "conversion-domain"
              "partial numeric conversion has no explicit total Boolean domain guards"
          ]))
  | BinE ((`DivOp | `ModOp), _, left, right) ->
    (match merge_domain_results [ recurse left; recurse right ] with
    | Error blockers -> Error blockers
    | Ok (domains, guards, diagnostics) ->
      let lowered = Expr_translate.lower_value ctx env origin exp in
      (match lowered.term, bool_domain_terms lowered.guards with
      | Some _, Some (_ :: _ as operator_domains)
        when not (result_has_fatal lowered) ->
        Ok
          ( domains @ operator_domains
          , guards
          , diagnostics @ lowered.diagnostics )
      | _ ->
        Error
          [ blocker origin exp "operator-domain"
              "partial division or modulo has no explicit total Boolean source-domain guards"
          ]))
  | ProjE ({ it = UncaseE (scrutinee, mixop); note = payload_typ; _ }, index)
    when uncase_projection_domain ctx scrutinee mixop payload_typ index ->
    recurse scrutinee
  | ProjE (inner, index) when tuple_projection_domain inner index -> recurse inner
  | UncaseE (scrutinee, mixop)
    when uncase_projection_domain ctx scrutinee mixop exp.note 0 ->
    recurse scrutinee
  | DotE (inner, atom) when simple_struct_field ctx inner.note atom -> recurse inner
  | ProjE _ | UncaseE _ | DotE _ ->
    Error [ blocker origin exp "partial-destructor"
      "equality cannot observe a projection, constructor destruction, or record field without a structural domain certificate" ]
  | LenE inner | LiftE inner -> recurse inner
  | SubE (inner, source, target) when certified_subtyping ctx source target ->
    recurse inner
  | _ ->
    (match total_exp ?bound_vars ctx env origin exp with
    | Total -> Ok ([], [], [])
    | Blocked blockers -> Error blockers)

let first_failure_alternatives domains final_condition =
  let rec loop prefix alternatives = function
    | [] -> List.rev (List.rev_append prefix [ final_condition ] :: alternatives)
    | domain :: rest ->
      let failure =
        List.rev_append prefix
          [ Maude_ir.BoolCond (Maude_ir.App ("not_", [ domain ])) ]
      in
      loop (Maude_ir.BoolCond domain :: prefix) (failure :: alternatives) rest
  in
  loop [] [] domains

let equality_operands = function
  | Maude_ir.App ("_==_", [ left; right ]) -> Some (left, right)
  | Maude_ir.Var _ | Maude_ir.Const _ | Maude_ir.Qid _ | Maude_ir.App _ -> None

let same_equality (left, right) (actual_left, actual_right) =
  (left = actual_left && right = actual_right)
  || (left = actual_right && right = actual_left)

let condition_matches_domain domain = function
  | Maude_ir.BoolCond term ->
    term = domain
    || (match equality_operands domain, equality_operands term with
        | Some expected, Some actual -> same_equality expected actual
        | None, _ | _, None -> false)
  | Maude_ir.EqCond (left, right)
  | Maude_ir.MatchCond (left, right) ->
    (match equality_operands domain with
    | Some expected -> same_equality expected (left, right)
    | None -> false)
  | Maude_ir.MembershipCond _ -> false

let condition_is_domain domains condition =
  List.exists (fun domain -> condition_matches_domain domain condition) domains

let constrained_first_failures constraints domains final_condition =
  first_failure_alternatives domains final_condition
  |> List.map (fun failure -> constraints @ failure)

let stable_unique items =
  List.fold_left
    (fun unique item -> if List.mem item unique then unique else item :: unique)
    [] items
  |> List.rev

let false_condition_alternatives
    ?bound_vars ctx env origin op left_exp right_exp =
  match
    index_domains ?bound_vars ctx env origin left_exp,
    index_domains ?bound_vars ctx env origin right_exp
  with
  | Error left, Error right -> Error (left @ right)
  | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
  | Ok (left_domains, left_guards, left_diagnostics),
    Ok (right_domains, right_guards, right_diagnostics) ->
    let domains = left_domains @ right_domains in
    if domains = [] && left_guards = [] && right_guards = [] then
      (match
         false_conditions ?bound_vars ctx env origin op left_exp right_exp
       with
      | Ok (conditions, diagnostics) -> Ok ([ conditions ], diagnostics)
      | Error blockers -> Error blockers)
    else
      let left = Expr_translate.lower_value ctx env origin left_exp in
      let right = Expr_translate.lower_value ctx env origin right_exp in
      (match left.term, right.term, op with
      | Some left_term, Some right_term, (`EqOp | `NeOp)
        when left.guards = [] && right.guards = []
             && not (result_has_fatal left) && not (result_has_fatal right) ->
        let false_op = if op = `EqOp then "_=/=_" else "_==_" in
        let final_condition =
          Maude_ir.BoolCond
            (Maude_ir.App (false_op, [ left_term; right_term ]))
        in
        Ok
          ( constrained_first_failures [] domains final_condition
          , left_diagnostics @ right_diagnostics
            @ left.diagnostics @ right.diagnostics )
      | Some left_term, Some right_term, (`EqOp | `NeOp)
        when not (result_has_fatal left) && not (result_has_fatal right) ->
        let false_op = if op = `EqOp then "_=/=_" else "_==_" in
        let final_condition =
          Maude_ir.BoolCond
            (Maude_ir.App (false_op, [ left_term; right_term ]))
        in
        let constraints =
          (left.guards @ right.guards)
          |> List.filter (fun condition -> not (condition_is_domain domains condition))
        in
        Ok
          ( constrained_first_failures constraints domains final_condition
          , left_diagnostics @ right_diagnostics
            @ left.diagnostics @ right.diagnostics )
      | _ ->
        Error
          [ index_domain_blocker origin left_exp
              "indexed equality operands did not lower to guard-free equality-comparable Maude terms"
          ])

let source_equality_alternatives
    ?bound_vars ctx env origin left_exp right_exp =
  match
    index_domains ?bound_vars ctx env origin left_exp,
    index_domains ?bound_vars ctx env origin right_exp
  with
  | Error left, Error right -> Error (left @ right)
  | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
  | Ok (left_domains, _left_guards, left_diagnostics),
    Ok (right_domains, _right_guards, right_diagnostics) ->
    let left = Expr_translate.lower_value ctx env origin left_exp in
    let right = Expr_translate.lower_value ctx env origin right_exp in
    (match left.term, right.term with
    | Some left_term, Some right_term
      when not (result_has_fatal left) && not (result_has_fatal right) ->
      let requirements =
        left.guards @ right.guards |> stable_unique
      in
      let domains = left_domains @ right_domains in
      let constraints =
        requirements
        |> List.filter (fun condition -> not (condition_is_domain domains condition))
      in
      let failure =
        constrained_first_failures constraints domains
          (Maude_ir.BoolCond
             (Maude_ir.App ("_=/=_", [ left_term; right_term ])))
      in
      Ok
        ( left_term
        , right_term
        , requirements
        , failure
        , left_diagnostics @ right_diagnostics
          @ left.diagnostics @ right.diagnostics )
    | _ ->
      Error
        [ index_domain_blocker origin left_exp
            "structurally total source equality operands did not lower to comparable Maude terms"
        ])

let domain_first_failures domains =
  let rec loop prefix failures = function
    | [] -> List.rev failures
    | domain :: rest ->
      let failure =
        List.rev_append prefix
          [ Maude_ir.BoolCond (Maude_ir.App ("not_", [ domain ])) ]
      in
      loop (Maude_ir.BoolCond domain :: prefix) (failure :: failures) rest
  in
  loop [] [] domains

let source_definedness_alternatives ?bound_vars ctx env origin exp =
  match index_domains ?bound_vars ctx env origin exp with
  | Error blockers -> Error blockers
  | Ok (domains, _, domain_diagnostics) ->
    let lowered = Expr_translate.lower_value ctx env origin exp in
    (match lowered.term with
    | Some _ when not (result_has_fatal lowered) ->
      let positive = stable_unique lowered.guards in
      let domains = stable_unique domains in
      let emitted_domains =
        positive
        |> List.filter_map (fun condition ->
          List.find_opt
            (fun domain -> condition_matches_domain domain condition)
            domains)
      in
      if List.length emitted_domains <> List.length positive
         || not
              (List.for_all
                 (fun domain ->
                   List.exists
                     (fun condition -> condition_matches_domain domain condition)
                     positive)
                 domains)
      then
        Error
          [ blocker origin exp "binding-domain"
              "binding RHS guards are not the exact emitted image of its source-definedness domains"
          ]
      else
        Ok
          ( positive
          , domain_first_failures emitted_domains
          , domain_diagnostics @ lowered.diagnostics )
    | Some _ | None ->
      Error
        [ blocker origin exp "binding-domain"
            "binding RHS did not lower to a total value with explicit source-definedness guards"
        ])

type boolean_proof =
  { positive : Maude_ir.eq_condition list
  ; failure : Maude_ir.eq_condition list list
  ; diagnostics : Diagnostics.t list
  }

let dual_relational_comparison = function
  | `LtOp -> Some "_>=_"
  | `GtOp -> Some "_<=_"
  | `LeOp -> Some "_>_"
  | `GeOp -> Some "_<_"
  | `EqOp | `NeOp -> None

let rec structural_boolean_proof ?bound_vars ctx env origin exp =
  let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
  let lowering_blocker () =
    Error
      [ blocker origin exp "source-boolean-structure"
          "source Boolean structure did not lower without fatal diagnostics" ]
  in
  match exp.it with
  | CmpE (op, (`NatT | `IntT | `RatT | `RealT), left, right) ->
    (match dual_relational_comparison op with
    | None -> Error []
    | Some dual ->
      (match
         index_domains ?bound_vars ctx env origin left,
         index_domains ?bound_vars ctx env origin right
       with
      | Error left, Error right -> Error (left @ right)
      | Error blockers, Ok _ | Ok _, Error blockers -> Error blockers
      | Ok (left_domains, left_guards, left_diagnostics),
        Ok (right_domains, right_guards, right_diagnostics) ->
        let left_result = Expr_translate.lower_value ctx env origin left in
        let right_result = Expr_translate.lower_value ctx env origin right in
        (match lowered.term, left_result.term, right_result.term with
        | Some positive_term, Some left_term, Some right_term
          when not
            (List.exists Diagnostics.is_fatal
               (lowered.diagnostics @ left_result.diagnostics
                @ right_result.diagnostics)) ->
          let domains = left_domains @ right_domains in
          let guards =
            left_guards @ right_guards @ lowered.guards
            |> stable_unique
          in
          let constraints =
            guards
            |> List.filter (fun condition ->
              not (condition_is_domain domains condition))
          in
          let final_condition =
            Maude_ir.BoolCond
              (Maude_ir.App (dual, [ left_term; right_term ]))
          in
          Ok
            { positive = lowered.guards @ [ Maude_ir.BoolCond positive_term ]
            ; failure =
                constrained_first_failures constraints domains final_condition
            ; diagnostics =
                left_diagnostics @ right_diagnostics @ lowered.diagnostics
                @ left_result.diagnostics @ right_result.diagnostics
            }
        | _ -> lowering_blocker ())))
  | BinE ((`AndOp | `OrOp as op), `BoolT, left, right) ->
    (match
       structural_boolean_proof ?bound_vars ctx env origin left,
       structural_boolean_proof ?bound_vars ctx env origin right,
       lowered.term
     with
    | Ok left_proof, Ok right_proof, Some positive_term
      when not (List.exists Diagnostics.is_fatal lowered.diagnostics) ->
      let failure =
        match op with
        | `OrOp ->
          left_proof.failure
          |> List.concat_map (fun left_failure ->
            right_proof.failure
            |> List.map (fun right_failure ->
              left_failure @ right_failure))
        | `AndOp ->
          left_proof.failure
          @ (right_proof.failure
             |> List.map (fun right_failure ->
               left_proof.positive @ right_failure))
        | _ -> []
      in
      Ok
        { positive = lowered.guards @ [ Maude_ir.BoolCond positive_term ]
        ; failure
        ; diagnostics =
            lowered.diagnostics @ left_proof.diagnostics
            @ right_proof.diagnostics
        }
    | Error (_ :: _ as blockers), _, _ -> Error blockers
    | _, Error (_ :: _ as blockers), _ -> Error blockers
    | _ -> lowering_blocker ())
  | _ -> Error []

let source_boolean_alternatives ?bound_vars ctx env origin exp =
  match structural_boolean_proof ?bound_vars ctx env origin exp with
  | Ok proof -> Ok (proof.positive, proof.failure, proof.diagnostics)
  | Error (_ :: _ as structural_blockers) -> Error structural_blockers
  | Error [] ->
  match total_exp ?bound_vars ctx env origin exp with
  | Blocked blockers -> Error blockers
  | Total ->
    let lowered = Expr_translate.lower_bool_condition ctx env origin exp in
    (match lowered.term with
    | None ->
      Error [ blocker origin exp "lowering"
        "structurally total source Boolean observer did not lower to a Maude Bool term" ]
    | Some _ when result_has_fatal lowered ->
      Error [ blocker origin exp "lowering"
        "structurally total source Boolean observer retained a fatal lowering diagnostic" ]
    | Some term ->
      let positive = lowered.guards @ [ Maude_ir.BoolCond term ] in
      match exp.it with
      | CmpE ((`EqOp | `NeOp as op), _, left, right) ->
        (match false_condition_alternatives
                 ?bound_vars ctx env origin op left right with
        | Error blockers -> Error blockers
        | Ok (failure, diagnostics) ->
          Ok (positive, failure, lowered.diagnostics @ diagnostics))
      | _ when lowered.guards = [] ->
        Ok
          ( positive
          , [ [ Maude_ir.BoolCond (Maude_ir.App ("not_", [ term ])) ] ]
          , lowered.diagnostics )
      | _ ->
        Error [ blocker origin exp "guarded-boolean"
          "generic Boolean complement requires a guard-free total source observer or an explicit source-ordered guard-domain proof" ])
