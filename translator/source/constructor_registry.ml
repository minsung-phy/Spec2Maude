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
  ; payload_witnesses : Maude_ir.term list
  ; payload_sorts : Maude_ir.sort list
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
  ; reason : string
  }

type family_coverage =
  | Closed of entry list
  | Open of string list

type source_case =
  { case_category : string
  ; case_static_key : string option
  ; case_origin : Origin.t
  }

type t =
  { mutable entries : entry list
  ; mutable late_entries : entry list
  ; mutable inclusions : inclusion list
  ; mutable source_cases : source_case list
  ; mutable surfaces_resolved : bool
  }

let create () =
  { entries = []
  ; late_entries = []
  ; inclusions = []
  ; source_cases = []
  ; surfaces_resolved = false
  }

let copy t =
  { entries = t.entries
  ; late_entries = t.late_entries
  ; inclusions = t.inclusions
  ; source_cases = t.source_cases
  ; surfaces_resolved = t.surfaces_resolved
  }

let replace ~target ~source =
  target.entries <- source.entries;
  target.late_entries <- source.late_entries;
  target.inclusions <- source.inclusions;
  target.source_cases <- source.source_cases;
  target.surfaces_resolved <- source.surfaces_resolved

let compatible_static_key requested actual =
  requested = actual || (Option.is_some requested && actual = None)

let same_static_key left right =
  left = right

let same_shape (left : entry) (right : entry) =
  left.source_category = right.source_category
  && same_static_key left.static_args_key right.static_args_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && left.status = right.status

let same_source_entry left right =
  same_shape left right
  && left.declaring_category = right.declaring_category
  && left.payload_labels = right.payload_labels
  && left.payload_witnesses = right.payload_witnesses
  && left.payload_sorts = right.payload_sorts
  && left.construction_domain = right.construction_domain
  && left.origin = right.origin

type registration =
  | Registered
  | Already_registered
  | Rejected_after_resolution

let register_checked t (entry : entry) =
  if List.exists (same_source_entry entry) t.entries then
    Already_registered
  else if t.surfaces_resolved then (
    if not (List.exists (same_source_entry entry) t.late_entries) then
      t.late_entries <- t.late_entries @ [ entry ];
    Rejected_after_resolution)
  else (
    t.entries <- t.entries @ [ entry ];
    Registered)

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

let resolve_surfaces t =
  if not t.surfaces_resolved then (
    let entries = t.entries in
    t.entries <-
      entries
      |> List.map (fun entry ->
        let base = entry.constructor_op in
        let family =
          List.filter (fun candidate -> candidate.constructor_op = base) entries
        in
        let constructor_op = constructor_surface base family entry.arity in
        let projection_ops =
          entry.projection_ops
          |> List.mapi (fun index _ -> Naming.projection_op constructor_op index)
        in
        { entry with constructor_op; projection_ops });
    t.surfaces_resolved <- true)

let same_inclusion left right =
  left.parent_category = right.parent_category
  && same_static_key left.parent_static_args_key right.parent_static_args_key
  && left.child_category = right.child_category
  && same_static_key left.child_static_args_key right.child_static_args_key
  && left.reason = right.reason

let register_inclusion t (inclusion : inclusion) =
  if not (List.exists (same_inclusion inclusion) t.inclusions) then
    t.inclusions <- t.inclusions @ [ inclusion ]

let note_source_case t ~source_category ~static_args_key origin =
  if
    not
      (List.exists
         (fun case ->
           case.case_category = source_category
           && case.case_static_key = static_args_key
           && case.case_origin = origin)
         t.source_cases)
  then
    t.source_cases <-
      { case_category = source_category
      ; case_static_key = static_args_key
      ; case_origin = origin
      }
      :: t.source_cases

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
             (fun (inclusion : inclusion) -> inclusion.origin = case.case_origin)
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

let emitted_lookup_from_matches = function
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
    | entries -> Ambiguous entries)

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

let schema_emitted_lookup_from_matches entries =
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
    if List.mem source_category visited then
      Missing
    else
      let direct = direct_entries t ~source_category ~static_args_key ~mixop ~arity in
      match direct with
      | [] ->
        let child_results =
          child_inclusions t ~parent_category:source_category ~parent_static_args_key:static_args_key
          |> List.map (fun inclusion ->
            lookup_category (source_category :: visited) inclusion.child_category inclusion.child_static_args_key)
        in
        let found =
          child_results
          |> List.concat_map (function
            | Found entry -> [ entry ]
            | Ambiguous entries -> entries
            | Missing -> [])
        in
        (match found with
        | [] -> Missing
        | [ entry ] -> Found entry
        | entries -> Ambiguous entries)
      | [ entry ] -> Found entry
      | entries -> Ambiguous entries
  in
  lookup_category [] source_category static_args_key

let lookup_emitted t ~source_category ~static_args_key ~mixop ~arity =
  let rec lookup_category visited source_category static_args_key =
    if List.mem source_category visited then
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
      match emitted_lookup_from_matches exact_direct with
      | Found _ as found -> found
      | Ambiguous _ as ambiguous -> ambiguous
      | Missing ->
        (match emitted_lookup_from_matches generic_direct with
        | Found _ as found -> found
        | Ambiguous _ as ambiguous -> ambiguous
        | Missing ->
          (match schema_emitted_lookup_from_matches schema_direct with
          | Found _ as found -> found
          | Ambiguous _ as ambiguous -> ambiguous
          | Missing ->
          let child_results =
            child_inclusions t ~parent_category:source_category ~parent_static_args_key:static_args_key
            |> List.map (fun inclusion ->
              lookup_category
                (source_category :: visited)
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
          (match found with
          | [] -> Missing
          | [ entry ] -> Found entry
          | entries -> Ambiguous entries)))
  in
  lookup_category [] source_category static_args_key

let lookup_direct_emitted t ~source_category ~static_args_key ~mixop ~arity =
  let exact =
    direct_entries t ~source_category ~static_args_key ~mixop ~arity
  in
  match emitted_lookup_from_matches exact with
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
    (match emitted_lookup_from_matches generic with
    | Found _ as found -> found
    | Ambiguous _ as ambiguous -> ambiguous
    | Missing ->
      direct_entries_any_static_key t ~source_category ~mixop ~arity
      |> schema_emitted_lookup_from_matches)

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

let duplicate_shape_groups entries =
  entries
  |> List.fold_left
       (fun groups entry ->
         let same, rest =
           List.partition
             (function
               | [] -> false
               | head :: _ -> same_shape entry head)
             groups
         in
         match same with
         | [] -> [ entry ] :: rest
         | group :: _ -> (entry :: group) :: rest)
       []
  |> List.filter (fun group ->
    match group with
    | [] | [ _ ] -> false
    | entries ->
      let distinct =
        entries
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

let visible_collision_groups entries =
  entries
  |> List.filter (fun entry -> entry.status = Emitted)
  |> List.fold_left
       (fun groups entry ->
         let same, rest =
           List.partition
             (function
               | head :: _ -> same_visible_signature entry head
               | [] -> false)
             groups
         in
         match same with
         | [] -> [ entry ] :: rest
         | group :: _ -> (entry :: group) :: rest)
       []
  |> List.filter (function
    | [] | [ _ ] -> false
    | head :: rest -> not (List.for_all (same_raw_owner head) rest))

let diagnostics ~profile t =
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
          "Preload this exact source constructor before resolve_surfaces; resolved registries reject genuinely new entries instead of emitting an unresolved name"
        ())
  in
  let duplicate_shape_diagnostics =
    duplicate_shape_groups t.entries
    |> List.filter_map (function
    | [] ->
      invalid_arg "Constructor_registry.diagnostics: empty duplicate-shape group"
    | entry :: rest ->
      let constructors =
        (entry :: rest)
        |> List.map (fun entry -> entry.constructor_op)
        |> List.sort_uniq String.compare
      in
      Some
        (Diagnostics.make
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
           ()))
  in
  let visible_collision_diagnostics =
    visible_collision_groups t.entries
    |> List.map (function
      | [] | [ _ ] ->
        invalid_arg "Constructor_registry.diagnostics: invalid visible collision group"
      | entry :: rest ->
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
  late_registration_diagnostics
  @ duplicate_shape_diagnostics
  @ visible_collision_diagnostics
