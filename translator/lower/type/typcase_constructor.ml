open Il.Ast

type resolution =
  { resolved_constructor : string
  ; resolved_typ : typ
  ; projection_ops : string list
  ; registry_entry : Constructor_registry.entry
  ; uniform_payload_schema : bool
  }

type lookup =
  | Found of resolution
  | Missing
  | Blocked of string
  | Ambiguous of resolution list

type payload_certificate =
  { constructor_op : string
  ; arity : int
  ; payload_typs : typ list
  ; payload_sorts : Maude_ir.sort list
  ; payload_witnesses : Maude_ir.term list
  }

type ingress_certificate = payload_certificate

let certifies certificate ~constructor_op ~arity =
  String.equal certificate.constructor_op constructor_op
  && certificate.arity = arity

let certificate_of_entry entry =
  { constructor_op = entry.Constructor_registry.constructor_op
  ; arity = entry.arity
  ; payload_typs = entry.payload_typs
  ; payload_sorts = entry.payload_sorts
  ; payload_witnesses = entry.payload_witnesses
  }

let complete_payload_schema entry =
  List.length entry.Constructor_registry.payload_typs = entry.arity
  && List.length entry.payload_sorts = entry.arity
  && List.length entry.payload_witnesses = entry.arity

let payload_certificate resolution =
  let entry = resolution.registry_entry in
  match entry.status, entry.construction_domain with
  | Constructor_registry.Emitted, Constructor_registry.Total_constructor
    when complete_payload_schema entry
         && resolution.uniform_payload_schema ->
    Some (certificate_of_entry entry)
  | _ -> None

let exact_payload_schema resolution =
  let entry = resolution.registry_entry in
  if entry.status = Constructor_registry.Emitted
     && entry.arity > 0
     && complete_payload_schema entry
     && resolution.uniform_payload_schema
  then
    Some (certificate_of_entry entry)
  else None

let ingress_certificate ctx ~constructor_op ~arity =
  Constructor_registry.entries (Context.constructors ctx)
  |> List.filter (fun entry ->
       entry.Constructor_registry.status = Constructor_registry.Emitted
       && String.equal entry.constructor_op constructor_op
       && entry.arity = arity)
  |> function
  | entry :: _ ->
    if complete_payload_schema entry
       && Constructor_registry.uniform_payload_schema
            (Context.constructors ctx) entry
    then Some (certificate_of_entry entry)
    else None
  | [] -> None

let ingress_payload_guards ctx certificate args =
  if List.length args <> certificate.arity then []
  else
    let rec guards typs sorts args witnesses =
      match typs, sorts, args, witnesses with
      | typ :: typs, sort :: sorts, arg :: args, witness :: witnesses ->
        Typecheck_guard.for_typ ctx typ sort arg witness
        @ guards typs sorts args witnesses
      | [], [], [], [] -> []
      | _ ->
        invalid_arg
          "Typcase_constructor.ingress_payload_guards: inconsistent certificate"
    in
    guards
      certificate.payload_typs
      certificate.payload_sorts
      args
      certificate.payload_witnesses

let certifies_ground resolution ~constructor_op arg_exps =
  match exact_payload_schema resolution with
  | Some certificate
    when certifies certificate
           ~constructor_op
           ~arity:(List.length arg_exps) ->
    List.for_all2
      (fun exp typ ->
        Il.Free.Set.is_empty Il.Free.(free_exp exp).varid
        && Il.Eq.eq_typ exp.note typ)
      arg_exps certificate.payload_typs
  | Some _ | None -> false

let certifies_payloads certificate ~typs ~sorts ~witnesses =
  List.length certificate.payload_typs = List.length typs
  && List.for_all2 Il.Eq.eq_typ certificate.payload_typs typs
  && certificate.payload_sorts = sorts
  && certificate.payload_witnesses = witnesses

let certifies_payload_typs certificate typs =
  List.length certificate.payload_typs = List.length typs
  && List.for_all2 Il.Eq.eq_typ certificate.payload_typs typs

let canonical_constructor_typ ctx typ =
  match
    Subtype_plan.canonical_typ
      ~il_env:(Context.il_env ctx)
      ~static_typ_env:(Context.static_typ_env ctx)
      typ
  with
  | Ok typ -> Ok typ
  | Error _ -> Error "type-family instance matching is irreducible"

let describe_static_key = function
  | None -> "<generic>"
  | Some key -> key

let describe_registry_entry entry =
  Printf.sprintf
    "%s category=%s key=%s mixop=%s arity=%d status=%s"
    entry.Constructor_registry.constructor_op
    entry.source_category
    (describe_static_key entry.static_args_key)
    (Il.Print.string_of_mixop entry.mixop)
    entry.arity
    (Constructor_registry.status_to_string entry.status)

let constructor_lookup_miss_detail ctx ~source_category ~static_args_key ~mixop ~arity =
  let entries = Constructor_registry.entries (Context.constructors ctx) in
  let same_category =
    entries
    |> List.filter (fun entry ->
      entry.Constructor_registry.source_category = source_category)
  in
  let same_category_arity =
    same_category
    |> List.filter (fun entry -> entry.Constructor_registry.arity = arity)
  in
  let same_category_mixop =
    same_category
    |> List.filter (fun entry ->
      entry.Constructor_registry.arity = arity
      && Il.Eq.eq_mixop entry.mixop mixop)
  in
  let sample entries =
    entries
    |> List.map describe_registry_entry
    |> List.sort_uniq String.compare
    |> fun entries ->
      match entries with
      | [] -> ""
      | _ ->
        entries
        |> List.filteri (fun index _ -> index < 5)
        |> String.concat "; "
  in
  if same_category = [] then
    Printf.sprintf
      "no TypD constructor entries are registered for category %s"
      source_category
  else if same_category_arity = [] then
    Printf.sprintf
      "category %s has registered constructors, but none with arity %d; requested mixop %s and key %s"
      source_category
      arity
      (Il.Print.string_of_mixop mixop)
      (describe_static_key static_args_key)
  else if same_category_mixop = [] then
    Printf.sprintf
      "category %s has arity-%d constructors, but none with requested mixop %s and key %s; candidates: %s"
      source_category
      arity
      (Il.Print.string_of_mixop mixop)
      (describe_static_key static_args_key)
      (sample same_category_arity)
  else
    Printf.sprintf
      "category %s has matching mixop/arity entries, but not as an emitted constructor visible at key %s; candidates: %s"
      source_category
      (describe_static_key static_args_key)
      (sample same_category_mixop)

let resolution ctx resolved_typ (entry : Constructor_registry.entry) =
  { resolved_constructor = entry.constructor_op
  ; resolved_typ
  ; projection_ops = entry.projection_ops
  ; registry_entry = entry
  ; uniform_payload_schema =
      Constructor_registry.uniform_payload_schema
        (Context.constructors ctx) entry
  }

let resolve_emitted ctx typ mixop ~arity =
  match canonical_constructor_typ ctx typ with
  | Error reason ->
    Blocked
      (reason
       ^ "; constructor lowering requires a source-complete AliasT instance match")
  | Ok resolved_typ ->
    let key_env = Static_key.of_static_typ_env (Context.static_typ_env ctx) in
    match Static_key.typ_ref ~env:key_env resolved_typ with
    | Some { Static_key.category_id; static_args_key } ->
      let source_category = Naming.source_owner category_id in
      (match
         Constructor_registry.lookup_emitted
           (Context.constructors ctx)
           ~source_category
           ~static_args_key
           ~mixop
           ~arity
       with
      | Constructor_registry.Found entry -> Found (resolution ctx resolved_typ entry)
      | Constructor_registry.Ambiguous entries ->
        Ambiguous (List.map (resolution ctx resolved_typ) entries)
      | Constructor_registry.Missing ->
        (match
           Constructor_registry.lookup_visible
             (Context.constructors ctx)
             ~source_category
             ~static_args_key
             ~mixop
             ~arity
         with
        | Constructor_registry.Found entry ->
          Blocked
            (Printf.sprintf
               "matching TypD constructor exists but is registered as %s at %s"
               (Constructor_registry.status_to_string entry.Constructor_registry.status)
               (Origin.summary entry.Constructor_registry.origin))
        | Constructor_registry.Ambiguous entries ->
          Blocked
            (Printf.sprintf
               "matching TypD constructor shape is non-emitted or ambiguous: %s"
               (entries
                |> List.map (fun entry ->
                  Printf.sprintf
                    "%s[%s]@%s"
                    entry.Constructor_registry.constructor_op
                    (Constructor_registry.status_to_string entry.Constructor_registry.status)
                    (Origin.summary entry.Constructor_registry.origin))
                |> String.concat ", "))
        | Constructor_registry.Missing ->
          Blocked
            (constructor_lookup_miss_detail
               ctx
               ~source_category
               ~static_args_key
               ~mixop
               ~arity)))
    | None -> Missing
