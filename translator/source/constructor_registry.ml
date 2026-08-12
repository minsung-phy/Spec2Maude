type status =
  | Emitted
  | Skipped
  | Unsupported

type construction_domain =
  | Total_constructor
  | Certified_representation_constructor
  | Length_guarded_representation_constructor of
      { payload_index : int
      ; closed_bound : Il.Ast.exp
      ; guard_origin : Origin.t
      }
  | Guarded_constructor of string

type case_schema =
  { payload_typ : Il.Ast.typ
  ; case_binds : Il.Ast.quant list
  ; case_prems : Il.Ast.prem list
  ; instance_binds : Il.Ast.quant list
  ; instance_args : Il.Ast.arg list
  ; static_args_key : string option
  ; construction_domain : construction_domain
  ; origin : Origin.t
  }

let case_schema
    ~payload_typ ~case_binds ~case_prems ~instance_binds ~instance_args
    ~static_args_key ~construction_domain ~origin =
  { payload_typ; case_binds; case_prems; instance_binds; instance_args
  ; static_args_key; construction_domain; origin
  }

type payload_label =
  | Source_category of string
  | Primitive_type of string
  | Structural_payload

type entry =
  { source_category : string
  ; declaring_category : string
  ; static_args_key : string option
  ; mixop : Il.Ast.mixop
  ; arity : int
  ; constructor_op : string
  ; projection_ops : string list
  ; payload_labels : payload_label list
  ; payload_typs : Il.Ast.typ list
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
  ; source_case : case_schema option
  ; origin : Origin.t
  ; enclosing : string list
  ; status : status
  ; construction_domain : construction_domain
  }

type lookup =
  | Found of entry
  | Missing
  | Ambiguous of entry list

type projection_lookup =
  | Projection_found of entry
  | Projection_missing
  | Projection_ambiguous of entry list

type inclusion =
  { parent_category : string
  ; parent_static_args_key : string option
  ; child_category : string
  ; child_static_args_key : string option
  ; origin : Origin.t
  ; covered_origins : Origin.t list
  ; reason : string
  }

type family_coverage =
  | Closed of entry list
  | Open of string list

type category_case =
  { case_category : string
  ; case_static_key : string option
  ; case_origin : Origin.t
  }

type late_source_fact =
  | Late_inclusion of inclusion
  | Late_source_case of category_case

type t =
  { mutable entries : entry list
  ; mutable late_entries : entry list
  ; mutable late_source_facts : late_source_fact list
  ; mutable inclusions : inclusion list
  ; mutable source_cases : category_case list
  ; mutable equivalences : Constructor_equivalence.t option
  ; mutable surfaces_resolved : bool
  }

let create () =
  { entries = []
  ; late_entries = []
  ; late_source_facts = []
  ; inclusions = []
  ; source_cases = []
  ; equivalences = None
  ; surfaces_resolved = false
  }

let copy t =
  { entries = t.entries
  ; late_entries = t.late_entries
  ; late_source_facts = t.late_source_facts
  ; inclusions = t.inclusions
  ; source_cases = t.source_cases
  ; equivalences = t.equivalences
  ; surfaces_resolved = t.surfaces_resolved
  }

let replace ~target ~source =
  target.entries <- source.entries;
  target.late_entries <- source.late_entries;
  target.late_source_facts <- source.late_source_facts;
  target.inclusions <- source.inclusions;
  target.source_cases <- source.source_cases;
  target.equivalences <- source.equivalences;
  target.surfaces_resolved <- source.surfaces_resolved

let compatible_static_key requested actual =
  requested = actual || (Option.is_some requested && actual = None)

let same_static_key left right =
  left = right

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

let same_case_schema left right =
  Il.Eq.eq_typ left.payload_typ right.payload_typ
  && Il.Eq.eq_list Il.Eq.eq_param left.case_binds right.case_binds
  && Il.Eq.eq_list Il.Eq.eq_prem left.case_prems right.case_prems
  && Il.Eq.eq_list Il.Eq.eq_param left.instance_binds right.instance_binds
  && Il.Eq.eq_list Il.Eq.eq_arg left.instance_args right.instance_args
  && left.static_args_key = right.static_args_key
  && same_construction_domain
       left.construction_domain right.construction_domain

let same_optional_source_case left right =
  match left, right with
  | Some left, Some right ->
    same_case_schema left right && left.origin = right.origin
  | None, None -> true
  | None, Some _ | Some _, None -> false

let same_shape (left : entry) (right : entry) =
  left.source_category = right.source_category
  && same_static_key left.static_args_key right.static_args_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && left.status = right.status

let same_source_entry left right =
  let same_source =
    same_shape left right
    && left.declaring_category = right.declaring_category
    && same_optional_source_case left.source_case right.source_case
    && left.origin = right.origin
  in
  same_source
  && match left.source_case, right.source_case with
     | Some _, Some _ -> true
     | None, None ->
       left.payload_labels = right.payload_labels
       && List.length left.payload_typs = List.length right.payload_typs
       && List.for_all2 Il.Eq.eq_typ left.payload_typs right.payload_typs
       && left.payload_witnesses = right.payload_witnesses
       && left.payload_sorts = right.payload_sorts
       && same_construction_domain
            left.construction_domain right.construction_domain
     | None, Some _ | Some _, None -> false

let same_payload_schema left right =
  left.status = Emitted
  && right.status = Emitted
  && left.constructor_op = right.constructor_op
  && left.arity = right.arity
  && List.length left.payload_typs = List.length right.payload_typs
  && List.for_all2 Il.Eq.eq_typ left.payload_typs right.payload_typs
  && left.payload_sorts = right.payload_sorts
  && left.payload_witnesses = right.payload_witnesses
  && same_optional_source_case left.source_case right.source_case
  && same_construction_domain left.construction_domain right.construction_domain

let uniform_payload_schema t entry =
  t.entries
  |> List.filter (fun candidate ->
    candidate.status = Emitted
    && candidate.constructor_op = entry.constructor_op)
  |> List.for_all (same_payload_schema entry)

let equivalence_domain = function
  | Total_constructor -> Constructor_equivalence.Total_constructor
  | Certified_representation_constructor ->
    Constructor_equivalence.Certified_representation_constructor
  | Length_guarded_representation_constructor certificate ->
    Constructor_equivalence.Length_guarded_representation_constructor
      { payload_index = certificate.payload_index
      ; closed_bound = certificate.closed_bound
      ; guard_origin = certificate.guard_origin
      }
  | Guarded_constructor reason -> Constructor_equivalence.Guarded_constructor reason

let equivalence_case source =
  Constructor_equivalence.source_case
    ~payload_typ:source.payload_typ
    ~case_binds:source.case_binds
    ~case_prems:source.case_prems
    ~instance_binds:source.instance_binds
    ~instance_args:source.instance_args
    ~static_args_key:source.static_args_key
    ~construction_domain:(equivalence_domain source.construction_domain)
    ~origin:source.origin

let proof_entry entry =
  { Constructor_equivalence.source_category = entry.source_category
  ; static_args_key = entry.static_args_key
  ; mixop = entry.mixop
  ; arity = entry.arity
  ; payload_typs = entry.payload_typs
  ; payload_witnesses = entry.payload_witnesses
  ; payload_sorts = entry.payload_sorts
  ; source_case = Option.map equivalence_case entry.source_case
  ; origin = entry.origin
  ; emitted = entry.status = Emitted
  }

let proof_entries t = List.map proof_entry t.entries

let proof_cases t =
  t.source_cases
  |> List.map (fun case ->
    { Constructor_equivalence.case_category = case.case_category
    ; case_static_key = case.case_static_key
    ; case_origin = case.case_origin
    })

let proof_inclusions t =
  t.inclusions
  |> List.map (fun inclusion ->
    { Constructor_equivalence.parent_category = inclusion.parent_category
    ; parent_static_args_key = inclusion.parent_static_args_key
    ; child_category = inclusion.child_category
    ; child_static_args_key = inclusion.child_static_args_key
    ; covered_origins = inclusion.covered_origins
    })

let canonical_owner t entry =
  match t.equivalences with
  | None -> Some entry
  | Some equivalences ->
    (match
       Constructor_equivalence.canonical_entry
         equivalences (proof_entry entry)
    with
    | None -> None
    | Some canonical ->
      t.entries
      |> List.find_opt (fun candidate ->
        candidate.source_category = canonical.source_category
        && candidate.static_args_key = canonical.static_args_key
        && Il.Eq.eq_mixop candidate.mixop canonical.mixop
        && candidate.arity = canonical.arity
        && candidate.origin = canonical.origin))

let equivalent t source target =
  match t.equivalences with
  | None -> same_source_entry source target
  | Some equivalences ->
    Constructor_equivalence.equivalent
      equivalences (proof_entry source) (proof_entry target)

let apply_equivalent_surfaces t =
  if not t.surfaces_resolved then
    t.entries <-
      t.entries
      |> List.map (fun entry ->
        match t.equivalences with
        | None -> entry
        | Some equivalences ->
          (match canonical_owner t entry with
          | None -> entry
          | Some owner ->
            let constructor_op =
              if Constructor_equivalence.shared equivalences (proof_entry entry)
              then Naming.constructor_op entry.mixop
              else owner.constructor_op
            in
            { entry with
              constructor_op
            ; projection_ops =
                List.mapi
                  (fun index _ -> Naming.projection_op constructor_op index)
                  entry.projection_ops
            }))

let uses_shared_surface t entry =
  match t.equivalences with
  | None -> false
  | Some equivalences ->
    Constructor_equivalence.shared equivalences (proof_entry entry)

let declaration_owner t entry =
  match canonical_owner t entry with
  | Some owner when
      owner.source_category = entry.source_category
      && owner.static_args_key = entry.static_args_key
      && Il.Eq.eq_mixop owner.mixop entry.mixop
      && owner.arity = entry.arity
      && owner.origin = entry.origin -> Some owner
  | Some _ -> None
  | None -> if t.equivalences = None then Some entry else None

type declaration_identity =
  { declaration_name : string
  ; declaration_domain : Maude_ir.type_ref list
  ; declaration_kind : Maude_ir.op_kind
  ; declaration_range : Maude_ir.sort
  ; declaration_attrs : Maude_ir.attr list
  }

let normalize_attr = function
  | Maude_ir.Frozen positions ->
    Maude_ir.Frozen (List.sort_uniq Int.compare positions)
  | Maude_ir.Assoc -> Maude_ir.Assoc
  | Maude_ir.Comm -> Maude_ir.Comm
  | Maude_ir.Ctor -> Maude_ir.Ctor
  | Maude_ir.Id term -> Maude_ir.Id term

let declaration_identity (declaration : Maude_ir.op_decl) =
  { declaration_name = declaration.name
  ; declaration_domain = declaration.args
  ; declaration_kind = declaration.kind
  ; declaration_range = declaration.result
  ; declaration_attrs =
      declaration.attrs
      |> List.map normalize_attr
      |> List.sort_uniq compare
  }

let constructor_declaration (entry : entry) =
  { Maude_ir.name = entry.constructor_op
  ; args = List.map Maude_ir.sort_ref entry.payload_sorts
  ; result = Maude_ir.sort "SpectecTerminal"
  ; kind = if entry.arity = 0 then Maude_ir.Total else Maude_ir.Partial
  ; attrs = [ Maude_ir.Ctor ]
  }

let projection_declarations (entry : entry) =
  List.map2
    (fun name result ->
      { Maude_ir.name
      ; args = [ Maude_ir.sort_ref (Maude_ir.sort "SpectecTerminal") ]
      ; result
      ; kind = Maude_ir.Partial
      ; attrs = []
      })
    entry.projection_ops entry.payload_sorts

let entry_declarations entry =
  constructor_declaration entry :: projection_declarations entry

type registration =
  | Registered
  | Already_registered
  | Schema_mismatch of entry * string list
  | Rejected_after_resolution

let same_exact_owner left right =
  left.source_category = right.source_category
  && left.declaring_category = right.declaring_category
  && same_static_key left.static_args_key right.static_args_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && left.origin = right.origin

let compare_declaration_owner (left : entry) (right : entry) =
  match String.compare (Origin.summary left.origin) (Origin.summary right.origin) with
  | 0 ->
    (match String.compare left.source_category right.source_category with
    | 0 ->
      (match String.compare left.declaring_category right.declaring_category with
      | 0 ->
        (match Option.compare String.compare left.static_args_key right.static_args_key with
        | 0 ->
          (match Xl.Mixop.compare left.mixop right.mixop with
          | 0 -> Int.compare left.arity right.arity
          | order -> order)
        | order -> order)
      | order -> order)
    | order -> order)
  | order -> order

let declaration_candidates t =
  t.entries
  |> List.filter (fun entry ->
    entry.status = Emitted
    && Option.is_some (declaration_owner t entry))
  |> List.concat_map (fun entry ->
    entry_declarations entry
    |> List.map (fun declaration -> entry, declaration_identity declaration))

let owns_op_declaration t entry declaration =
  let identity = declaration_identity declaration in
  declaration_candidates t
  |> List.filter_map (fun (candidate, candidate_identity) ->
    if candidate_identity = identity then Some candidate else None)
  |> function
  | owner :: _ -> same_exact_owner owner entry
  | [] -> false

let schema_differences expected actual =
  let difference condition field fields =
    if condition then fields else field :: fields
  in
  let domain = function
    | Total_constructor -> "total"
    | Certified_representation_constructor -> "certified-representation"
    | Length_guarded_representation_constructor certificate ->
      "length-guarded[payload=" ^ string_of_int certificate.payload_index ^ "]"
    | Guarded_constructor reason -> "guarded:" ^ reason
  in
  []
  |> difference
       (List.length expected.projection_ops = List.length actual.projection_ops)
       "projection count"
  |> difference (expected.payload_labels = actual.payload_labels) "payload labels"
  |> difference
       (List.length expected.payload_typs = List.length actual.payload_typs
        && List.for_all2 Il.Eq.eq_typ expected.payload_typs actual.payload_typs)
       "payload types"
  |> difference
       (expected.payload_witnesses = actual.payload_witnesses)
       "payload witnesses"
  |> difference (expected.payload_sorts = actual.payload_sorts) "payload sorts"
  |> difference (expected.status = actual.status) "status"
  |> difference
       (same_construction_domain
          expected.construction_domain actual.construction_domain)
       (Printf.sprintf
          "construction domain (preloaded=%s; actual=%s)"
          (domain expected.construction_domain)
          (domain actual.construction_domain))
  |> difference
       (same_optional_source_case expected.source_case actual.source_case)
       "source case"
  |> List.rev

let register_checked t (entry : entry) =
  match List.filter (same_exact_owner entry) t.entries with
  | [ expected ] ->
    (match schema_differences expected entry with
    | [] -> Already_registered
    | differences -> Schema_mismatch (expected, differences))
  | _ :: _ :: _ ->
    Schema_mismatch
      (entry, [ "preloaded exact owner is ambiguous" ])
  | [] when Option.is_some t.equivalences || t.surfaces_resolved ->
    if not (List.exists (same_source_entry entry) t.late_entries) then
      t.late_entries <- t.late_entries @ [ entry ];
    Rejected_after_resolution
  | [] ->
    t.entries <- t.entries @ [ entry ];
    Registered

let register t entry =
  ignore (register_checked t entry)

let payload_label = function
  | Source_category category | Primitive_type category ->
    Some (Naming.source_slug ~lower:true category)
  | Structural_payload -> None

let payload_suffix entries arity =
  let suffixes =
    entries
    |> List.filter (fun entry -> entry.arity = arity)
    |> List.filter_map (fun entry ->
      let labels = List.map payload_label entry.payload_labels in
      if List.for_all Option.is_some labels then
        Some (String.concat "-" (List.map Option.get labels))
      else None)
    |> List.sort_uniq String.compare
  in
  match suffixes with
  | [ suffix ] when suffix <> "" -> suffix
  | _ -> "arity-" ^ string_of_int arity

let constructor_surface base entries arity =
  let arities =
    entries
    |> List.map (fun entry -> entry.arity)
    |> List.sort_uniq Int.compare
  in
  match arities with
  | [] | [ _ ] -> base
  | _ when arity = 0 -> base
  | _ -> base ^ "-" ^ payload_suffix entries arity

let resolve_arity_surfaces t =
  if not t.surfaces_resolved then (
    let entries = t.entries in
    t.entries <-
      entries
      |> List.map (fun entry ->
        let base = entry.constructor_op in
        let family =
          List.filter (fun candidate -> candidate.constructor_op = base) entries
        in
        let constructor_op =
          if uses_shared_surface t entry then base
          else constructor_surface base family entry.arity
        in
        let projection_ops =
          entry.projection_ops
          |> List.mapi (fun index _ -> Naming.projection_op constructor_op index)
        in
        { entry with constructor_op; projection_ops });
    t.surfaces_resolved <- true)

let resolve ~il_env ~source_index t script =
  if Option.is_some t.equivalences || t.surfaces_resolved then
    invalid_arg "Constructor_registry.resolve: registry is already resolved";
  t.equivalences <-
    Some
      (Constructor_equivalence.analyze
         ~il_env ~source_index
         ~entries:(proof_entries t)
         ~cases:(proof_cases t)
         ~inclusions:(proof_inclusions t)
         script);
  apply_equivalent_surfaces t;
  resolve_arity_surfaces t

let same_inclusion left right =
  left.parent_category = right.parent_category
  && same_static_key left.parent_static_args_key right.parent_static_args_key
  && left.child_category = right.child_category
  && same_static_key left.child_static_args_key right.child_static_args_key
  && left.origin = right.origin
  && left.covered_origins = right.covered_origins
  && left.reason = right.reason

let same_category_case left right =
  left.case_category = right.case_category
  && left.case_static_key = right.case_static_key
  && left.case_origin = right.case_origin

let same_late_source_fact left right =
  match left, right with
  | Late_inclusion left, Late_inclusion right -> same_inclusion left right
  | Late_source_case left, Late_source_case right -> same_category_case left right
  | Late_inclusion _, Late_source_case _
  | Late_source_case _, Late_inclusion _ -> false

let note_late_source_fact t fact =
  if not (List.exists (same_late_source_fact fact) t.late_source_facts) then
    t.late_source_facts <- t.late_source_facts @ [ fact ]

let is_resolved t = Option.is_some t.equivalences || t.surfaces_resolved

let register_inclusion t (inclusion : inclusion) =
  if List.exists (same_inclusion inclusion) t.inclusions then
    ()
  else if is_resolved t then
    note_late_source_fact t (Late_inclusion inclusion)
  else
    t.inclusions <- t.inclusions @ [ inclusion ]

let note_source_case t ~source_category ~static_args_key origin =
  let case =
    { case_category = source_category
    ; case_static_key = static_args_key
    ; case_origin = origin
    }
  in
  if List.exists (same_category_case case) t.source_cases then
    ()
  else if is_resolved t then
    note_late_source_fact t (Late_source_case case)
  else
    t.source_cases <- case :: t.source_cases

let entries t =
  t.entries

let is_constructor_op t name =
  List.exists
    (fun entry -> entry.status = Emitted && String.equal entry.constructor_op name)
    t.entries

let inclusions t =
  t.inclusions

let visible_emitted_entries t ~source_category ~static_args_key =
  let same_surface left right =
    Il.Eq.eq_mixop left.mixop right.mixop
    && left.arity = right.arity
    && left.constructor_op = right.constructor_op
    && left.projection_ops = right.projection_ops
  in
  let rec collect visited category key =
    if List.mem (category, key) visited then
      []
    else
      let visited = (category, key) :: visited in
      let direct =
        t.entries
        |> List.filter (fun entry ->
          entry.source_category = category
          && same_static_key entry.static_args_key key
          && entry.status = Emitted)
      in
      let inherited =
        child_inclusions t ~parent_category:category ~parent_static_args_key:key
        |> List.concat_map (fun inclusion ->
          collect visited inclusion.child_category inclusion.child_static_args_key)
      in
      direct @ inherited
  and child_inclusions t ~parent_category ~parent_static_args_key =
    t.inclusions
    |> List.filter (fun inclusion ->
      inclusion.parent_category = parent_category
      && (same_static_key inclusion.parent_static_args_key parent_static_args_key
          ||
          match parent_static_args_key, inclusion.parent_static_args_key with
          | Some _, None -> true
          | _ -> false))
  in
  collect [] source_category static_args_key
  |> List.fold_left
       (fun entries entry ->
         if List.exists (same_surface entry) entries then entries
         else entry :: entries)
       []
  |> List.rev

let family_coverage t ~source_category ~static_args_key =
  let rec collect visited category key =
    if List.mem (category, key) visited then
      [], [ "constructor inclusion cycle at `" ^ category ^ "`" ]
    else
      let visited = (category, key) :: visited in
      let cases =
        t.source_cases
        |> List.filter (fun case ->
          case.case_category = category
          && compatible_static_key key case.case_static_key)
      in
      let entries =
        t.entries
        |> List.filter (fun entry ->
          entry.source_category = category
          && compatible_static_key key entry.static_args_key)
      in
      let inclusions =
        t.inclusions
        |> List.filter (fun inclusion ->
          inclusion.parent_category = category
          && compatible_static_key key inclusion.parent_static_args_key)
      in
      let child_entries, child_blockers =
        inclusions
        |> List.fold_left
             (fun (entries, blockers) inclusion ->
               let child_entries, child_blockers =
                 collect
                   visited
                   inclusion.child_category
                   inclusion.child_static_args_key
               in
               child_entries @ entries, child_blockers @ blockers)
             ([], [])
      in
      let case_is_represented case =
        List.exists
          (fun (entry : entry) -> entry.origin = case.case_origin)
          entries
        || List.exists
             (fun (inclusion : inclusion) ->
               List.mem case.case_origin inclusion.covered_origins)
             inclusions
      in
      let blockers =
        (if cases = [] then
           [ "no recorded source VariantT cases for `" ^ category ^ "`" ]
         else
           cases
           |> List.filter_map (fun case ->
             if case_is_represented case then None
             else
               Some
                  ("source constructor case has no same-origin entry or inclusion visible to this static key at "
                  ^ Origin.summary case.case_origin)))
        @ (if cases <> [] && entries = [] && child_entries = [] then
             [ "recorded source constructor cases have no constructor entry visible to this static key" ]
           else
             [])
        @ (entries
           |> List.filter_map (fun entry ->
             if entry.status = Emitted then None
             else
               Some
                 ("constructor `" ^ entry.constructor_op ^ "` is "
                  ^ status_to_string entry.status)))
        @ child_blockers
      in
      entries @ child_entries, blockers
  and status_to_string = function
    | Emitted -> "Emitted"
    | Skipped -> "Skipped"
    | Unsupported -> "Unsupported"
  in
  let entries, blockers = collect [] source_category static_args_key in
  let constructors =
    entries |> List.map (fun entry -> entry.constructor_op) in
  let ambiguous =
    constructors |> List.sort_uniq String.compare |> List.length
    <> List.length constructors
  in
  let blockers =
    if ambiguous then "constructor identities are ambiguous" :: blockers
    else blockers
  in
  match blockers with
  | [] -> Closed entries
  | _ -> Open (List.sort_uniq String.compare blockers)

let lookup t ~source_category ~static_args_key ~mixop ~arity =
  let matches =
    t.entries
    |> List.filter (fun entry ->
      entry.source_category = source_category
      && same_static_key entry.static_args_key static_args_key
      && Il.Eq.eq_mixop entry.mixop mixop
      && entry.arity = arity)
  in
  match matches with
  | [] -> Missing
  | [ entry ] -> Found entry
  | entries -> Ambiguous entries

let lookup_at_origin t ~source_category ~static_args_key ~mixop ~arity ~origin =
  let matches =
    t.entries
    |> List.filter (fun entry ->
      entry.source_category = source_category
      && same_static_key entry.static_args_key static_args_key
      && Il.Eq.eq_mixop entry.mixop mixop
      && entry.arity = arity
      && entry.origin = origin)
  in
  match matches with
  | [] -> Missing
  | [ entry ] -> Found entry
  | entries -> Ambiguous entries

let direct_entries t ~source_category ~static_args_key ~mixop ~arity =
  t.entries
  |> List.filter (fun entry ->
    entry.source_category = source_category
    && same_static_key entry.static_args_key static_args_key
    && Il.Eq.eq_mixop entry.mixop mixop
    && entry.arity = arity)

let direct_entries_any_static_key t ~source_category ~mixop ~arity =
  t.entries
  |> List.filter (fun entry ->
    entry.source_category = source_category
    && Il.Eq.eq_mixop entry.mixop mixop
    && entry.arity = arity)

let same_emitted_surface left right =
  left.status = Emitted
  && right.status = Emitted
  && left.constructor_op = right.constructor_op
  && left.projection_ops = right.projection_ops

let equivalent_emitted_surface t left right =
  same_emitted_surface left right && equivalent t left right

let emitted_lookup_from_matches t = function
  | [] -> Missing
  | [ ({ status = Emitted; _ } as entry) ] -> Found entry
  | [ _ ] -> Missing
  | entries ->
    let emitted =
      entries
      |> List.filter (fun entry -> entry.status = Emitted)
    in
    (match emitted with
    | [] -> Missing
    | [ entry ] -> Found entry
    | entry :: rest ->
      if List.for_all (equivalent_emitted_surface t entry) rest then Found entry
      else Ambiguous emitted)

let schema_emitted_lookup_from_matches t entries =
  ignore t;
  let emitted =
    entries |> List.filter (fun entry -> entry.status = Emitted)
  in
  match emitted with
  | [] -> Missing
  | [ entry ] -> Found entry
  | entry :: rest ->
    if List.for_all (same_emitted_surface entry) rest then
      Found entry
    else
      Ambiguous emitted

let child_inclusions t ~parent_category ~parent_static_args_key =
  t.inclusions
  |> List.filter (fun inclusion ->
    inclusion.parent_category = parent_category
    && (same_static_key inclusion.parent_static_args_key parent_static_args_key
        ||
        match parent_static_args_key, inclusion.parent_static_args_key with
        | Some _, None -> true
        | _ -> false))

let lookup_visible t ~source_category ~static_args_key ~mixop ~arity =
  let rec lookup_category visited source_category static_args_key =
    if List.mem (source_category, static_args_key) visited then
      Missing
    else
      let direct = direct_entries t ~source_category ~static_args_key ~mixop ~arity in
      match direct with
      | [] ->
        let child_results =
          child_inclusions t ~parent_category:source_category ~parent_static_args_key:static_args_key
          |> List.map (fun inclusion ->
            lookup_category
              ((source_category, static_args_key) :: visited)
              inclusion.child_category inclusion.child_static_args_key)
        in
        let found =
          child_results
          |> List.concat_map (function
            | Found entry -> [ entry ]
            | Ambiguous entries -> entries
            | Missing -> [])
        in
        emitted_lookup_from_matches t found
      | entries ->
        (match emitted_lookup_from_matches t entries with
        | Missing -> Ambiguous entries
        | found -> found)
  in
  lookup_category [] source_category static_args_key

let lookup_emitted t ~source_category ~static_args_key ~mixop ~arity =
  let rec lookup_category visited source_category static_args_key =
    if List.mem (source_category, static_args_key) visited then
      Missing
    else
      let exact_direct =
        direct_entries t ~source_category ~static_args_key ~mixop ~arity
      in
      let generic_direct =
        match static_args_key with
        | None -> []
        | Some _ -> direct_entries t ~source_category ~static_args_key:None ~mixop ~arity
      in
      let schema_direct =
        direct_entries_any_static_key t ~source_category ~mixop ~arity
      in
      match emitted_lookup_from_matches t exact_direct with
      | Found _ as found -> found
      | Ambiguous _ as ambiguous -> ambiguous
      | Missing ->
        (match emitted_lookup_from_matches t generic_direct with
        | Found _ as found -> found
        | Ambiguous _ as ambiguous -> ambiguous
        | Missing ->
          (match schema_emitted_lookup_from_matches t schema_direct with
          | Found _ as found -> found
          | Ambiguous _ as ambiguous -> ambiguous
          | Missing ->
          let child_results =
            child_inclusions t ~parent_category:source_category ~parent_static_args_key:static_args_key
            |> List.map (fun inclusion ->
              lookup_category
                ((source_category, static_args_key) :: visited)
                inclusion.child_category
                inclusion.child_static_args_key)
          in
          let found =
            child_results
            |> List.concat_map (function
              | Found entry -> [ entry ]
              | Ambiguous entries -> entries
              | Missing -> [])
          in
          emitted_lookup_from_matches t found))
  in
  lookup_category [] source_category static_args_key

let lookup_direct_emitted t ~source_category ~static_args_key ~mixop ~arity =
  let exact =
    direct_entries t ~source_category ~static_args_key ~mixop ~arity
  in
  match emitted_lookup_from_matches t exact with
  | Found _ as found -> found
  | Ambiguous _ as ambiguous -> ambiguous
  | Missing ->
    let generic =
      match static_args_key with
      | None -> []
      | Some _ ->
        direct_entries
          t ~source_category ~static_args_key:None ~mixop ~arity
    in
    (match emitted_lookup_from_matches t generic with
    | Found _ as found -> found
    | Ambiguous _ as ambiguous -> ambiguous
    | Missing ->
      direct_entries_any_static_key t ~source_category ~mixop ~arity
      |> schema_emitted_lookup_from_matches t)

let category_includes t ~parent_category ~child_category =
  let rec reaches visited category =
    category = child_category
    ||
    if List.mem category visited then
      false
    else
      t.inclusions
      |> List.exists (fun inclusion ->
        inclusion.parent_category = category
        && reaches (category :: visited) inclusion.child_category)
  in
  reaches [] parent_category

let lookup_unary_projection t ~projection_op =
  let matches =
    t.entries
    |> List.filter (fun entry ->
      entry.status = Emitted
      && entry.arity = 1
      && entry.projection_ops = [ projection_op ])
  in
  match matches with
  | [] -> Projection_missing
  | [ entry ] -> Projection_found entry
  | entry :: rest ->
    if List.for_all (fun candidate -> same_emitted_surface entry candidate) rest then
      Projection_found entry
    else
      Projection_ambiguous matches

let has_wrapper t ~source_category ~static_args_key =
  t.entries
  |> List.exists (fun entry ->
    entry.source_category = source_category
    && same_static_key entry.static_args_key static_args_key
    && entry.status = Emitted
    && entry.arity = 1
    && entry.constructor_op = Naming.wrapper_constructor_in_category source_category)

let status_to_string = function
  | Emitted -> "Emitted"
  | Skipped -> "Skipped"
  | Unsupported -> "Unsupported"

let construction_domain_to_string = function
  | Total_constructor -> "total"
  | Certified_representation_constructor -> "certified-representation"
  | Length_guarded_representation_constructor certificate ->
    Printf.sprintf
      "length-guarded-representation[payload=%d; guard=%s]"
      certificate.payload_index
      (Origin.summary certificate.guard_origin)
  | Guarded_constructor reason -> "guarded: " ^ reason

let group_by same entries =
  entries
  |> List.fold_left
       (fun groups entry ->
         let matching, rest =
           List.partition
             (fun (head, _) -> same entry head)
             groups
         in
         match matching with
         | [] -> (entry, []) :: rest
         | (head, tail) :: _ -> (entry, head :: tail) :: rest)
       []

let duplicate_shape_groups entries =
  entries
  |> group_by same_shape
  |> List.filter (fun (head, tail) ->
    match tail with
    | [] -> false
    | _ ->
      let distinct =
        head :: tail
        |> List.map (fun entry ->
          entry.constructor_op,
          entry.projection_ops,
          entry.payload_labels,
          entry.payload_witnesses,
          entry.construction_domain,
          Origin.summary entry.origin)
        |> List.sort_uniq compare
      in
      List.length distinct > 1)

let same_visible_signature left right =
  left.status = Emitted
  && right.status = Emitted
  && left.constructor_op = right.constructor_op
  && left.payload_sorts = right.payload_sorts

let same_raw_owner left right =
  left.source_category = right.source_category
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity

let visible_collision_groups t entries =
  entries
  |> List.filter (fun entry -> entry.status = Emitted)
  |> group_by same_visible_signature
  |> List.filter (fun (head, tail) ->
       tail <> []
       && not
            (List.for_all
               (fun entry ->
                 same_raw_owner head entry
                 || equivalent t head entry)
               tail))

let type_ref_name = function
  | Maude_ir.SortRef sort -> Maude_ir.sort_name sort
  | Maude_ir.KindRef kind ->
    "[" ^ Maude_ir.sort_name (Maude_ir.kind_sort kind) ^ "]"

let attr_name = function
  | Maude_ir.Assoc -> "assoc"
  | Maude_ir.Comm -> "comm"
  | Maude_ir.Ctor -> "ctor"
  | Maude_ir.Id _ -> "id"
  | Maude_ir.Frozen positions ->
    "frozen(" ^ String.concat "," (List.map string_of_int positions) ^ ")"

let declaration_identity_summary identity =
  let domain =
    match List.map type_ref_name identity.declaration_domain with
    | [] -> "none"
    | sorts -> String.concat " " sorts
  in
  let arrow =
    match identity.declaration_kind with
    | Maude_ir.Total -> ":"
    | Maude_ir.Partial -> "~>"
  in
  let attrs =
    match List.map attr_name identity.declaration_attrs with
    | [] -> ""
    | attrs -> " [" ^ String.concat " " attrs ^ "]"
  in
  Printf.sprintf
    "%s : %s %s %s%s"
    identity.declaration_name domain arrow
    (Maude_ir.sort_name identity.declaration_range) attrs

let same_declaration_key left right =
  left.declaration_name = right.declaration_name
  && List.length left.declaration_domain = List.length right.declaration_domain

let module_surface_diagnostics ~profile t statements =
  let declarations =
    statements
    |> List.filter_map (fun statement ->
      match statement.Maude_ir.node with
      | Maude_ir.OpDecl declaration ->
        Some (declaration_identity declaration, statement.origin)
      | Maude_ir.SortDecl _ | Maude_ir.SubsortDecl _ | Maude_ir.VarDecl _
      | Maude_ir.Mb _ | Maude_ir.Cmb _ | Maude_ir.Eq _ | Maude_ir.Ceq _
      | Maude_ir.Rl _ | Maude_ir.Crl _ -> None)
  in
  let collision_summary collisions =
    collisions
    |> List.map (fun (identity, declaration_origin) ->
      declaration_identity_summary identity
      ^ " at " ^ Origin.summary declaration_origin)
    |> List.sort_uniq String.compare
    |> String.concat ", "
  in
  let shared_targets =
    t.entries
    |> List.filter (fun (entry : entry) ->
      entry.status = Emitted && uses_shared_surface t entry)
    |> List.filter_map (declaration_owner t)
    |> List.concat_map (fun entry ->
      entry_declarations entry
      |> List.map (fun declaration ->
        entry, declaration_identity declaration))
    |> List.sort_uniq compare
  in
  let consume_owned target owner_origin declarations =
    let rec consume seen = function
      | [] -> List.rev seen
      | (identity, origin) :: rest
        when identity = target && origin = owner_origin ->
        List.rev_append seen rest
      | declaration :: rest -> consume (declaration :: seen) rest
    in
    consume [] declarations
  in
  let target_diagnostics =
    shared_targets
    |> List.filter_map (fun ((entry : entry), target) ->
      let collisions =
        consume_owned target entry.origin declarations
        |> List.filter (fun (identity, _) -> same_declaration_key target identity)
      in
      match collisions with
      | [] -> None
      | collisions ->
        Some
          (Diagnostics.make
             ~category:Diagnostics.Unsupported
             ~origin:entry.origin ~enclosing:entry.enclosing ~profile
             ~constructor:"ConstructorRegistry/module-shared-target-collision"
             ~reason:
               (Printf.sprintf
                  "shared constructor target `%s`/%d conflicts by final Maude name and arity with unrelated operator declarations: %s"
                  target.declaration_name
                  (List.length target.declaration_domain)
                  (collision_summary collisions))
             ~suggestion:
               "Keep each shared constructor and projection name/arity disjoint from every unrelated final Maude operator"
             ()))
  in
  let reserved_diagnostics =
    shared_targets
    |> List.filter_map (fun ((entry : entry), identity) ->
      if not (Naming.is_reserved_operator_name identity.declaration_name) then None
      else
        Some
          (Diagnostics.make
             ~category:Diagnostics.Unsupported
             ~origin:entry.origin ~enclosing:entry.enclosing ~profile
             ~constructor:"ConstructorRegistry/reserved-shared-surface"
             ~reason:
               (Printf.sprintf
                  "shared constructor surface `%s`/%d collides with a Maude keyword, imported literal, or numeric token"
                  identity.declaration_name
                  (List.length identity.declaration_domain))
             ~suggestion:
               "Use a source mixop whose shared surface is not reserved by the final Maude module"
             ()))
  in
  target_diagnostics @ reserved_diagnostics

let diagnostics ~profile t =
  let shared_surface_collisions =
    t.entries
    |> List.filter (fun entry ->
      entry.status = Emitted
      && uses_shared_surface t entry
      && Option.is_some (declaration_owner t entry))
    |> group_by (fun left right ->
      left.constructor_op = right.constructor_op && left.arity = right.arity)
    |> List.filter_map (fun (head, tail) ->
      match tail with
      | [] -> None
      | _ ->
        let entries = head :: tail |> List.sort compare_declaration_owner in
        let owner = List.hd entries in
        let class_summary entry =
          let source_surfaces =
            t.entries
            |> List.filter (fun candidate -> equivalent t entry candidate)
            |> List.map (fun candidate ->
              Naming.constructor_op_in_category
                candidate.source_category candidate.mixop)
            |> List.sort_uniq String.compare
            |> String.concat ", "
          in
          let declaration = constructor_declaration entry in
          Printf.sprintf
            "{%s} owned at %s with %s"
            source_surfaces (Origin.summary entry.origin)
            (declaration_identity_summary (declaration_identity declaration))
        in
        Some
          (Diagnostics.make
             ~category:Diagnostics.Unsupported
             ~origin:owner.origin
             ~constructor:"ConstructorRegistry/shared-surface-collision"
             ~enclosing:owner.enclosing
             ~profile
             ~reason:
               (Printf.sprintf
                  "distinct certified constructor-equivalence classes claim the same unqualified target `%s`/%d: %s"
                  owner.constructor_op owner.arity
                  (entries |> List.map class_summary |> String.concat "; "))
             ~suggestion:
               "Keep the unqualified mixop surface unique by name, arity, typed signature, and certified equivalence class; do not merge unrelated source constructors"
             ()))
  in
  let declaration_collision_diagnostics =
    declaration_candidates t
    |> group_by (fun (_left_entry, left) (_right_entry, right) ->
      left.declaration_name = right.declaration_name
      && left.declaration_domain = right.declaration_domain)
    |> List.filter_map (fun (head, tail) ->
      let candidates = head :: tail in
      let identities =
        candidates
        |> List.map snd
        |> List.sort_uniq compare
      in
      match identities with
      | [] | [ _ ] -> None
      | identities ->
        let entry =
          candidates
          |> List.map fst
          |> List.sort compare_declaration_owner
          |> List.hd
        in
        Some
          (Diagnostics.make
             ~category:Diagnostics.Unsupported
             ~origin:entry.origin
             ~constructor:"ConstructorRegistry/op-declaration-collision"
             ~enclosing:entry.enclosing
             ~profile
             ~reason:
               ("the same constructor/projection declaration surface has incompatible typed identities: "
                ^ (identities
                   |> List.map declaration_identity_summary
                   |> String.concat "; "))
             ~suggestion:
               "Keep one exact arrow, range, and normalized attribute set for each emitted operator name/domain surface"
             ()))
  in
  let late_registration_diagnostics =
    t.late_entries
    |> List.map (fun (entry : entry) ->
      Diagnostics.make
        ~category:Diagnostics.Unsupported
        ~origin:entry.origin
        ~constructor:"ConstructorRegistry/late-registration"
        ~enclosing:entry.enclosing
        ~profile
        ~reason:
          (Printf.sprintf
             "constructor owner `%s` mixop `%s` arity %d was first discovered after constructor surfaces were resolved"
             entry.source_category
             (Il.Print.string_of_mixop entry.mixop)
             entry.arity)
        ~suggestion:
          "Preload this exact source constructor before Constructor_registry.resolve; resolved registries reject genuinely new entries instead of emitting an unresolved name"
        ())
  in
  let late_source_fact_diagnostics =
    t.late_source_facts
    |> List.map (function
      | Late_inclusion inclusion ->
        Diagnostics.make
          ~category:Diagnostics.Unsupported
          ~origin:inclusion.origin
          ~constructor:"ConstructorRegistry/late-inclusion"
          ~enclosing:inclusion.origin.path
          ?source_echo:inclusion.origin.source_echo
          ~profile
          ~reason:
            (Printf.sprintf
               "constructor inclusion `%s` -> `%s` was first discovered after constructor equivalence was resolved"
               inclusion.parent_category inclusion.child_category)
          ~suggestion:
            "Record this inclusion before Constructor_registry.resolve; resolved registries keep their certified source-fact snapshot unchanged"
          ()
      | Late_source_case case ->
        Diagnostics.make
          ~category:Diagnostics.Unsupported
          ~origin:case.case_origin
          ~constructor:"ConstructorRegistry/late-source-case"
          ~enclosing:case.case_origin.path
          ?source_echo:case.case_origin.source_echo
          ~profile
          ~reason:
            (Printf.sprintf
               "source constructor case for `%s` was first discovered after constructor equivalence was resolved"
               case.case_category)
          ~suggestion:
            "Record this source case before Constructor_registry.resolve; resolved registries keep their certified source-fact snapshot unchanged"
          ())
  in
  let duplicate_shape_diagnostics =
    duplicate_shape_groups t.entries
    |> List.map (fun (entry, rest) ->
      let constructors =
        (entry :: rest)
        |> List.map (fun entry -> entry.constructor_op)
        |> List.sort_uniq String.compare
      in
      Diagnostics.make
        ~category:Diagnostics.Unsupported
        ~origin:entry.origin
        ~constructor:"ConstructorRegistry/duplicate-shape"
        ~enclosing:entry.enclosing
        ~profile
        ~reason:
          (Printf.sprintf
             "source category `%s` mixop/arity shape maps to multiple emitted constructors: %s"
             entry.source_category
             (String.concat ", " constructors))
        ~suggestion:
          "Preserve the declaring category/static arguments in the registry key, or keep this shape Unsupported instead of guessing"
        ())
  in
  let visible_collision_diagnostics =
    visible_collision_groups t t.entries
    |> List.map (fun (entry, rest) ->
        let owners =
          entry :: rest
          |> List.map (fun candidate ->
            Printf.sprintf
              "%s/%s/%d"
              candidate.source_category
              (Il.Print.string_of_mixop candidate.mixop)
              candidate.arity)
          |> List.sort_uniq String.compare
        in
        Diagnostics.make
          ~category:Diagnostics.Unsupported
          ~origin:entry.origin
          ~constructor:"Unsupported/NamingCollision/constructor"
          ~enclosing:entry.enclosing
          ~profile
          ~reason:
            (Printf.sprintf
               "distinct raw constructor owners %s emit the same `%s` domain signature"
               (String.concat ", " owners)
               entry.constructor_op)
          ~suggestion:
            "Rename one source owner or make its payload domain structurally distinct; visible hashes and source-location suffixes are forbidden"
          ())
  in
  shared_surface_collisions @ declaration_collision_diagnostics
  @ late_registration_diagnostics
  @ late_source_fact_diagnostics
  @ duplicate_shape_diagnostics
  @ visible_collision_diagnostics
