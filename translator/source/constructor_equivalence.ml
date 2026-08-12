open Il.Ast
open Util.Source

type construction_domain =
  | Total_constructor
  | Certified_representation_constructor
  | Length_guarded_representation_constructor of
      { payload_index : int
      ; closed_bound : exp
      ; guard_origin : Origin.t
      }
  | Guarded_constructor of string

type source_case =
  { payload_typ : typ
  ; case_binds : quant list
  ; case_prems : prem list
  ; instance_binds : quant list
  ; instance_args : arg list
  ; static_args_key : string option
  ; construction_domain : construction_domain
  ; origin : Origin.t
  }

let source_case
    ~payload_typ ~case_binds ~case_prems ~instance_binds ~instance_args
    ~static_args_key ~construction_domain ~origin =
  { payload_typ; case_binds; case_prems; instance_binds; instance_args
  ; static_args_key; construction_domain; origin
  }

let same_construction_domain left right =
  match left, right with
  | Total_constructor, Total_constructor
  | Certified_representation_constructor,
    Certified_representation_constructor -> true
  | Length_guarded_representation_constructor left,
    Length_guarded_representation_constructor right ->
    left.payload_index = right.payload_index
    && Il.Eq.eq_exp left.closed_bound right.closed_bound
    && left.guard_origin = right.guard_origin
  | Guarded_constructor left, Guarded_constructor right -> left = right
  | Total_constructor, _
  | Certified_representation_constructor, _
  | Length_guarded_representation_constructor _, _
  | Guarded_constructor _, _ -> false

let same_source_case left right =
  Il.Eq.eq_typ left.payload_typ right.payload_typ
  && Il.Eq.eq_list Il.Eq.eq_param left.case_binds right.case_binds
  && Il.Eq.eq_list Il.Eq.eq_prem left.case_prems right.case_prems
  && Il.Eq.eq_list Il.Eq.eq_param left.instance_binds right.instance_binds
  && Il.Eq.eq_list Il.Eq.eq_arg left.instance_args right.instance_args
  && left.static_args_key = right.static_args_key
  && same_construction_domain
       left.construction_domain right.construction_domain

type entry =
  { source_category : string
  ; static_args_key : string option
  ; mixop : mixop
  ; arity : int
  ; payload_typs : typ list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; source_case : source_case option
  ; origin : Origin.t
  ; emitted : bool
  }

type category_case =
  { case_category : string
  ; case_static_key : string option
  ; case_origin : Origin.t
  }

type inclusion =
  { parent_category : string
  ; parent_static_args_key : string option
  ; child_category : string
  ; child_static_args_key : string option
  ; covered_origins : Origin.t list
  }

type owner =
  { category : string
  ; static_key : string option
  ; mixop : mixop
  ; arity : int
  ; origin : Origin.t
  }

type t =
  { entries : entry list
  ; edges : (owner * owner) list
  }

let same_origin left right =
  left.Origin.region = right.Origin.region
  && left.path = right.path
  && left.ast_constructor = right.ast_constructor
  && left.source_echo = right.source_echo

let owner entry =
  { category = entry.source_category
  ; static_key = entry.static_args_key
  ; mixop = entry.mixop
  ; arity = entry.arity
  ; origin = entry.origin
  }

let same_owner left right =
  left.category = right.category
  && left.static_key = right.static_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && same_origin left.origin right.origin

let compare_origin left right =
  match String.compare (Origin.source_location left) (Origin.source_location right) with
  | 0 ->
    (match List.compare String.compare left.Origin.path right.Origin.path with
    | 0 ->
      (match String.compare left.ast_constructor right.ast_constructor with
      | 0 -> Option.compare String.compare left.source_echo right.source_echo
      | order -> order)
    | order -> order)
  | order -> order

let owner_compare left right =
  match String.compare left.category right.category with
  | 0 ->
    (match Option.compare String.compare left.static_key right.static_key with
    | 0 ->
      (match Xl.Mixop.compare left.mixop right.mixop with
      | 0 ->
        (match Int.compare left.arity right.arity with
        | 0 -> compare_origin left.origin right.origin
        | order -> order)
      | order -> order)
    | order -> order)
  | order -> order

let safe_case (source : source_case) =
  source.static_args_key = None
  && source.case_binds = []
  && source.instance_binds = []
  && source.instance_args = []
  && source.case_prems = []
  && match source.construction_domain with
     | Total_constructor | Certified_representation_constructor -> true
     | Length_guarded_representation_constructor _ | Guarded_constructor _ -> false

let compatible source target =
  source.emitted
  && target.emitted
  && source.static_args_key = None
  && target.static_args_key = None
  && Il.Eq.eq_mixop source.mixop target.mixop
  && source.arity = target.arity
  && List.length source.payload_typs = source.arity
  && List.length target.payload_typs = target.arity
  && List.for_all2 Il.Eq.eq_typ source.payload_typs target.payload_typs
  && source.payload_sorts = target.payload_sorts
  && source.payload_witnesses = target.payload_witnesses
  && match source.source_case, target.source_case with
     | Some source_case, Some target_case ->
       safe_case source_case
       && safe_case target_case
       && same_source_case source_case target_case
     | None, _ | _, None -> false

let entry_has_origin entry origin =
  match entry.source_case with
  | Some source -> same_origin source.origin origin
  | None -> false

let add_unique same item items =
  if List.exists (same item) items then items else item :: items

let distinct_entries entries =
  entries |> List.fold_left (fun acc entry -> add_unique
    (fun left right -> same_owner (owner left) (owner right)) entry acc) []
  |> List.rev

let closed_surface ~entries ~cases ~inclusions category key =
  let rec collect visited category key =
    if List.exists (fun (seen, seen_key) -> seen = category && seen_key = key) visited then
      None
    else
      let visited = (category, key) :: visited in
      let source_cases =
        cases
        |> List.filter (fun case ->
          case.case_category = category && case.case_static_key = key)
      in
      let child_inclusions =
        inclusions
        |> List.filter (fun inclusion ->
          inclusion.parent_category = category
          && inclusion.parent_static_args_key = key)
      in
      let direct case =
        entries
        |> List.filter (fun entry ->
          entry.source_category = category
          && entry.static_args_key = key
          && entry_has_origin entry case.case_origin)
      in
      let inherited case =
        child_inclusions
        |> List.filter (fun inclusion ->
          List.exists (same_origin case.case_origin) inclusion.covered_origins)
      in
      let represented_once case =
        match direct case, inherited case with
        | [ { emitted = true; _ } ], [] | [], [ _ ] -> true
        | [], [] | _ -> false
      in
      let inclusion_is_exact inclusion =
        inclusion.covered_origins <> []
        && List.for_all
             (fun covered ->
               List.exists
                 (fun case -> same_origin covered case.case_origin)
                 source_cases)
             inclusion.covered_origins
      in
      if source_cases = []
         || not (List.for_all represented_once source_cases)
         || not (List.for_all inclusion_is_exact child_inclusions)
      then None
      else
        let direct_entries = List.concat_map direct source_cases in
        let rec children acc = function
          | [] -> Some acc
          | inclusion :: rest ->
            (match
               collect visited inclusion.child_category inclusion.child_static_args_key
             with
            | None -> None
            | Some child -> children (List.rev_append child acc) rest)
        in
        (match children [] child_inclusions with
        | None -> None
        | Some inherited_entries ->
          Some (distinct_entries (direct_entries @ List.rev inherited_entries)))
  in
  collect [] category key

let typd_count source_index id =
  Analysis.Source_index.find_by_id source_index id
  |> List.fold_left
       (fun count entry ->
         match entry.Analysis.Source_index.def.it with
         | TypD _ -> count + 1
         | RelD _ | DecD _ | GramD _ | RecD _ | HintD _ -> count)
       0

let canonical_typ il_env typ =
  try Some (Il.Eval.reduce_typ il_env typ) with Il.Eval.Irred -> None

let category_typ = function
  | { it = VarT (id, []); _ } as typ ->
    Some (Naming.source_owner id.it, id.it, typ)
  | _ -> None

let subtype il_env source target =
  try Il.Eval.sub_typ il_env source target with Il.Eval.Irred -> false

let certificate ~il_env ~source_index ~entries ~cases ~inclusions source target =
  match canonical_typ il_env source, canonical_typ il_env target with
  | Some source, Some target ->
    (match category_typ source, category_typ target with
    | Some (source_category, source_id, source),
      Some (target_category, target_id, target)
      when source_id <> target_id
           && typd_count source_index source_id = 1
           && typd_count source_index target_id = 1
           && subtype il_env source target ->
      (match
         closed_surface ~entries ~cases ~inclusions source_category None,
         closed_surface ~entries ~cases ~inclusions target_category None
       with
      | Some (_ :: _ as source_entries), Some target_entries ->
        let mapping source_entry =
          target_entries
          |> List.filter (compatible source_entry)
          |> function
          | [ target_entry ] -> Some (source_entry, target_entry)
          | [] | _ :: _ :: _ -> None
        in
        let mappings = List.map mapping source_entries in
        if List.for_all Option.is_some mappings then
          let mappings = List.map Option.get mappings in
          let targets = List.map (fun (_, target) -> owner target) mappings in
          let unique =
            List.fold_left
              (fun acc target -> add_unique same_owner target acc)
              [] targets
          in
          if List.length unique = List.length targets then Some mappings else None
        else None
      | None, _ | _, None | Some [], _ -> None)
    | _ -> None)
  | None, _ | _, None -> None

let collector =
  { (Il.Walk.base_collector [] List.rev_append) with
    collect_exp =
      (fun exp ->
        match exp.it with
        | SubE (_, source, target) -> [ source, target ], true
        | VarE _ | BoolE _ | NumE _ | TextE _ | UnE _ | BinE _ | CmpE _
        | TupE _ | ProjE _ | CaseE _ | UncaseE _ | OptE _ | TheE _ | StrE _
        | DotE _ | CompE _ | ListE _ | LiftE _ | MemE _ | LenE _ | CatE _
        | IdxE _ | SliceE _ | UpdE _ | ExtE _ | IfE _ | CallE _ | IterE _
        | CvtE _ -> [], true)
  }

let rec collect_param param =
  match param.it with
  | ExpP (_, typ) -> Il.Walk.collect_typ collector typ
  | TypP _ -> []
  | DefP (_, params, typ) | GramP (_, params, typ) ->
    List.concat_map collect_param params @ Il.Walk.collect_typ collector typ

let collect_deftyp deftyp =
  let collect_case (_, (typ, binds, prems), _) =
    Il.Walk.collect_typ collector typ
    @ List.concat_map collect_param binds
    @ List.concat_map (Il.Walk.collect_prem collector) prems
  in
  match deftyp.it with
  | AliasT typ -> Il.Walk.collect_typ collector typ
  | StructT fields ->
    fields |> List.concat_map (fun (_, body, hints) ->
      let typ, binds, prems = body in
      ignore hints;
      collect_case (Xl.Mixop.Seq [], (typ, binds, prems), []))
  | VariantT cases -> List.concat_map collect_case cases

let collect_inst inst =
  match inst.it with
  | InstD (binds, args, deftyp) ->
    List.concat_map collect_param binds
    @ List.concat_map (Il.Walk.collect_arg collector) args
    @ collect_deftyp deftyp

let rec collect_def def =
  match def.it with
  | TypD (_, params, insts) ->
    List.concat_map collect_param params @ List.concat_map collect_inst insts
  | RelD (_, params, _, typ, rules) ->
    List.concat_map collect_param params
    @ Il.Walk.collect_typ collector typ
    @ List.concat_map
        (fun rule -> match rule.it with
         | RuleD (_, binds, _, exp, prems) ->
           List.concat_map collect_param binds
           @ Il.Walk.collect_exp collector exp
           @ List.concat_map (Il.Walk.collect_prem collector) prems)
        rules
  | DecD (_, params, typ, clauses) ->
    List.concat_map collect_param params
    @ Il.Walk.collect_typ collector typ
    @ List.concat_map
        (fun clause -> match clause.it with
         | DefD (binds, args, exp, prems) ->
           List.concat_map collect_param binds
           @ List.concat_map (Il.Walk.collect_arg collector) args
           @ Il.Walk.collect_exp collector exp
           @ List.concat_map (Il.Walk.collect_prem collector) prems)
        clauses
  | GramD (_, params, typ, prods) ->
    List.concat_map collect_param params
    @ Il.Walk.collect_typ collector typ
    @ List.concat_map
        (fun prod -> match prod.it with
         | ProdD (binds, sym, exp, prems) ->
           List.concat_map collect_param binds
           @ Il.Walk.collect_sym collector sym
           @ Il.Walk.collect_exp collector exp
           @ List.concat_map (Il.Walk.collect_prem collector) prems)
        prods
  | RecD defs -> List.concat_map collect_def defs
  | HintD _ -> []

let same_typ_pair (source, target) (source', target') =
  Il.Eq.eq_typ source source' && Il.Eq.eq_typ target target'

let collected_subtypes script =
  script
  |> List.concat_map collect_def
  |> List.fold_left
       (fun pairs pair -> add_unique same_typ_pair pair pairs)
       []

let analyze ~il_env ~source_index ~entries ~cases ~inclusions script =
  let certificates =
    collected_subtypes script
    |> List.filter_map (fun (source, target) ->
      certificate ~il_env ~source_index ~entries ~cases ~inclusions source target)
  in
  let edges =
    certificates
    |> List.concat
    |> List.fold_left
         (fun edges (source, target) ->
           let source = owner source and target = owner target in
           if same_owner source target
              || List.exists
                   (fun (left, right) ->
                     same_owner source left && same_owner target right)
                   edges
           then edges
           else (source, target) :: edges)
         []
  in
  { entries; edges }

let equivalence_class analysis first =
  let rec visit seen = function
    | [] -> seen
    | current :: rest when List.exists (same_owner current) seen -> visit seen rest
    | current :: rest ->
      let adjacent =
        analysis.edges
        |> List.filter_map (fun (left, right) ->
          if same_owner current left then Some right
          else if same_owner current right then Some left
          else None)
      in
      visit (current :: seen) (List.rev_append adjacent rest)
  in
  visit [] [ first ]

let canonical_owner analysis entry =
  let class_ = equivalence_class analysis (owner entry) in
  let sinks =
    class_
    |> List.filter (fun candidate ->
      not
        (List.exists
           (fun (source, target) ->
             same_owner candidate source && not (same_owner source target))
           analysis.edges))
  in
  match if sinks = [] then class_ else sinks with
  | [] -> owner entry
  | first :: rest ->
    List.fold_left
      (fun least candidate ->
        if owner_compare candidate least < 0 then candidate else least)
      first rest

let canonical_entry analysis entry =
  let canonical = canonical_owner analysis entry in
  analysis.entries
  |> List.find_opt (fun candidate -> same_owner canonical (owner candidate))

let shared analysis entry =
  equivalence_class analysis (owner entry)
  |> List.map (fun owner -> owner.category)
  |> List.sort_uniq String.compare
  |> fun categories -> List.length categories > 1

let equivalent analysis left right =
  same_owner (canonical_owner analysis left) (canonical_owner analysis right)
