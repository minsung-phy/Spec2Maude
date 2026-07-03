type status =
  | Emitted
  | Skipped
  | Unsupported

type entry =
  { source_category : string
  ; declaring_category : string
  ; static_args_key : string option
  ; mixop : Il.Ast.mixop
  ; arity : int
  ; constructor_op : string
  ; projection_ops : string list
  ; payload_witnesses : Maude_ir.term list
  ; origin : Origin.t
  ; enclosing : string list
  ; status : status
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

type t =
  { mutable entries : entry list
  ; mutable inclusions : inclusion list
  }

let create () =
  { entries = []; inclusions = [] }

let same_static_key left right =
  left = right

let same_shape left right =
  left.source_category = right.source_category
  && same_static_key left.static_args_key right.static_args_key
  && Il.Eq.eq_mixop left.mixop right.mixop
  && left.arity = right.arity
  && left.status = right.status

let same_entry left right =
  same_shape left right
  && left.declaring_category = right.declaring_category
  && left.constructor_op = right.constructor_op
  && left.projection_ops = right.projection_ops
  && left.payload_witnesses = right.payload_witnesses
  && left.origin = right.origin

let register t entry =
  if not (List.exists (same_entry entry) t.entries) then
    t.entries <- t.entries @ [ entry ]

let same_inclusion left right =
  left.parent_category = right.parent_category
  && same_static_key left.parent_static_args_key right.parent_static_args_key
  && left.child_category = right.child_category
  && same_static_key left.child_static_args_key right.child_static_args_key
  && left.reason = right.reason

let register_inclusion t inclusion =
  if not (List.exists (same_inclusion inclusion) t.inclusions) then
    t.inclusions <- t.inclusions @ [ inclusion ]

let entries t =
  t.entries

let inclusions t =
  t.inclusions

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
          entry.payload_witnesses,
          Origin.summary entry.origin)
        |> List.sort_uniq compare
      in
      List.length distinct > 1)

let diagnostics ~profile t =
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
