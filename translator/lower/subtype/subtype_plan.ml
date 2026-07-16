open Il.Ast
open Util.Source

type t =
  | Identity
  | Injection of Subtype_injection.t

type surface_error =
  | Missing_typd of string
  | Ambiguous_typd of string
  | Not_variant of string
  | Missing_alternative of int
  | Non_emitted_alternative of int * Constructor_registry.status
  | Ambiguous_alternative of int
  | Incomplete_inclusion of int

type error =
  | Canonical_type_irreducible
  | Not_a_subtype
  | Unsupported_type_shape
  | Incomplete_source_surface of surface_error
  | Missing_target_alternative
  | Ambiguous_target_alternative
  | Incompatible_payload
  | Non_injective_target

let static_typ_subst static_typ_env =
  static_typ_env
  |> List.fold_left
       (fun subst (name, typ) ->
         Il.Subst.add_typid subst (name $ typ.at) typ)
       Il.Subst.empty

let canonical_typ ~il_env ~static_typ_env typ =
  let typ = Il.Subst.subst_typ (static_typ_subst static_typ_env) typ in
  try Ok (Il.Eval.reduce_typ il_env typ) with
  | Il.Eval.Irred -> Error Canonical_type_irreducible

let typ_ref static_typ_env typ =
  Static_key.typ_ref ~env:(Static_key.of_static_typ_env static_typ_env) typ

let typd_entries source_index id =
  Analysis.Source_index.find_by_id source_index id
  |> List.filter (fun entry ->
    match entry.Analysis.Source_index.def.it with
    | TypD _ -> true
    | _ -> false)

let direct_matches constructors category static_args_key mixop arity =
  let matches key =
    Constructor_registry.entries constructors
    |> List.filter (fun entry ->
      entry.Constructor_registry.source_category = category
      && entry.static_args_key = key
      && Il.Eq.eq_mixop entry.mixop mixop
      && entry.arity = arity)
  in
  match matches static_args_key, static_args_key with
  | [], Some _ -> matches None
  | entries, _ -> entries

let exact_inclusion constructors parent parent_key child child_key =
  Constructor_registry.inclusions constructors
  |> List.exists (fun inclusion ->
    inclusion.Constructor_registry.parent_category = parent
    && inclusion.parent_static_args_key = parent_key
    && inclusion.child_category = child
    && inclusion.child_static_args_key = child_key)

let direct_alternative constructors category key index mixop arity =
  match direct_matches constructors category key mixop arity with
  | [ ({ Constructor_registry.status = Emitted; _ } as entry) ] -> Ok [ entry ]
  | [ { status; _ } ] -> Error (Non_emitted_alternative (index, status))
  | [] -> Error (Missing_alternative index)
  | _ -> Error (Ambiguous_alternative index)

let visible_matches constructors category key mixop arity =
  let rec collect visited category key =
    if List.mem (category, key) visited then
      []
    else
      let visited = (category, key) :: visited in
      let direct = direct_matches constructors category key mixop arity in
      let inherited =
        Constructor_registry.inclusions constructors
        |> List.filter (fun inclusion ->
          inclusion.Constructor_registry.parent_category = category
          && inclusion.parent_static_args_key = key)
        |> List.concat_map (fun (inclusion : Constructor_registry.inclusion) ->
          collect visited inclusion.child_category inclusion.child_static_args_key)
      in
      direct @ inherited
  in
  collect [] category key |> List.sort_uniq compare

let rec source_surface ~il_env ~source_index ~constructors ~static_typ_env typ =
  match canonical_typ ~il_env ~static_typ_env typ with
  | Error _ -> Error Canonical_type_irreducible
  | Ok ({ it = VarT (id, _); _ } as typ) ->
    let category, key =
      match typ_ref static_typ_env typ with
      | Some reference ->
        Naming.source_owner reference.Static_key.category_id,
        reference.static_args_key
      | None -> Naming.source_owner id.it, None
    in
    (match typd_entries source_index id.it with
    | [] -> Error (Incomplete_source_surface (Missing_typd id.it))
    | _ :: _ :: _ -> Error (Incomplete_source_surface (Ambiguous_typd id.it))
    | [ _ ] ->
      (match (Il.Eval.reduce_typdef il_env typ).it with
      | AliasT _ | StructT _ ->
        Error (Incomplete_source_surface (Not_variant id.it))
      | VariantT cases ->
        let alternative index (mixop, (payload_typ, binds, prems), _hints) =
          let arity = List.length (Type_shape.typ_components payload_typ) in
          match direct_alternative constructors category key index mixop arity with
          | Ok entries -> Ok entries
          | Error (Missing_alternative _) ->
            let visible = visible_matches constructors category key mixop arity in
            (match visible with
            | [ ({ Constructor_registry.status = Emitted; _ } as entry) ] ->
              Ok [ entry ]
            | [ { status; _ } ] ->
              Error
                (Incomplete_source_surface
                   (Non_emitted_alternative (index, status)))
            | _ :: _ :: _ ->
              Error (Incomplete_source_surface (Ambiguous_alternative index))
            | [] ->
            match binds, prems, Type_shape.typ_components payload_typ with
            | [], [], [ _, child_typ ] when Type_shape.mixop_is_hole_only mixop ->
              (match canonical_typ ~il_env ~static_typ_env child_typ with
              | Ok ({ it = VarT (child_id, _); _ } as child_typ) ->
                let child_category, child_key =
                  match typ_ref static_typ_env child_typ with
                  | Some reference ->
                    Naming.source_owner reference.Static_key.category_id,
                    reference.static_args_key
                  | None -> Naming.source_owner child_id.it, None
                in
                if exact_inclusion constructors category key child_category child_key then
                  source_surface
                    ~il_env ~source_index ~constructors ~static_typ_env child_typ
                else
                  Error (Incomplete_source_surface (Incomplete_inclusion index))
              | _ -> Error (Incomplete_source_surface (Incomplete_inclusion index)))
            | _ -> Error (Incomplete_source_surface (Missing_alternative index)))
          | Error error -> Error (Incomplete_source_surface error)
        in
        let rec collect index acc = function
          | [] -> Ok (List.rev acc |> List.concat)
          | case :: rest ->
            (match alternative index case with
            | Ok entries -> collect (index + 1) (entries :: acc) rest
            | Error _ as error -> error)
        in
        collect 1 [] cases))
  | Ok _ -> Error Unsupported_type_shape

let same_payload_shape source target =
  source.Constructor_registry.payload_sorts = target.Constructor_registry.payload_sorts
  && source.payload_witnesses = target.payload_witnesses

let mapped_case constructors target_id source =
  match
    Constructor_registry.lookup_emitted
      constructors
      ~source_category:target_id.it
      ~static_args_key:None
      ~mixop:source.Constructor_registry.mixop
      ~arity:source.arity
  with
  | Constructor_registry.Found target when same_payload_shape source target ->
    Ok
      (Subtype_injection.make_case
         ~source_op:source.constructor_op
         ~target_op:target.constructor_op
         ~payload_sorts:source.payload_sorts)
  | Constructor_registry.Found _ -> Error Incompatible_payload
  | Constructor_registry.Missing -> Error Missing_target_alternative
  | Constructor_registry.Ambiguous _ -> Error Ambiguous_target_alternative

let rec collect_mappings acc = function
  | [] -> Ok (List.rev acc)
  | Ok case :: rest -> collect_mappings (case :: acc) rest
  | Error _ as error :: _ -> error

let injective_target_mapping cases =
  let targets = List.map Subtype_injection.target_op cases in
  List.length targets = List.length (List.sort_uniq String.compare targets)

let variant_plan
    ~il_env ~source_index ~constructors ~static_typ_env source source_id target_id =
  if
    Constructor_registry.category_includes
      constructors
      ~parent_category:target_id.it
      ~child_category:source_id.it
  then
    Ok Identity
  else
    match source_surface ~il_env ~source_index ~constructors ~static_typ_env source with
    | Error _ as error -> error
    | Ok sources ->
      let mappings = List.map (mapped_case constructors target_id) sources in
      (match collect_mappings [] mappings with
      | Error _ as error -> error
      | Ok cases
        when List.for_all (fun case ->
          Subtype_injection.source_op case = Subtype_injection.target_op case) cases ->
        Ok Identity
      | Ok cases when not (injective_target_mapping cases) ->
        Error Non_injective_target
      | Ok cases ->
        Ok
          (Injection
             (Subtype_injection.make
                ~source_category:source_id.it
                ~target_category:target_id.it
                ~cases)))

let make ~il_env ~source_index ~constructors ~static_typ_env source_typ target_typ =
  match
    canonical_typ ~il_env ~static_typ_env source_typ,
    canonical_typ ~il_env ~static_typ_env target_typ
  with
  | Error _, _ | _, Error _ -> Error Canonical_type_irreducible
  | Ok source, Ok target when Il.Eval.equiv_typ il_env source target -> Ok Identity
  | Ok { it = NumT _; _ }, Ok { it = NumT _; _ } -> Ok Identity
  | Ok ({ it = VarT (source_id, []); _ } as source),
    Ok ({ it = VarT (target_id, []); _ } as target) ->
    let is_subtype =
      try Il.Eval.sub_typ il_env source target with
      | Il.Eval.Irred -> false
    in
    if is_subtype then
      variant_plan
        ~il_env ~source_index ~constructors ~static_typ_env
        source source_id target_id
    else
      Error Not_a_subtype
  | _ -> Error Unsupported_type_shape

let describe_surface_error = function
  | Missing_typd id -> "source category `" ^ id ^ "` has no indexed TypD"
  | Ambiguous_typd id -> "source category `" ^ id ^ "` has multiple indexed TypD definitions"
  | Not_variant id -> "source category `" ^ id ^ "` does not reduce to VariantT"
  | Missing_alternative index ->
    Printf.sprintf "source VariantT alternative %d has no registered emitted representation" index
  | Non_emitted_alternative (index, status) ->
    Printf.sprintf
      "source VariantT alternative %d is registered as %s"
      index (Constructor_registry.status_to_string status)
  | Ambiguous_alternative index ->
    Printf.sprintf "source VariantT alternative %d has ambiguous registered representations" index
  | Incomplete_inclusion index ->
    Printf.sprintf "source VariantT alternative %d is an uncertified or incomplete category inclusion" index

let describe_error = function
  | Canonical_type_irreducible ->
    "SubE type-family instance matching is irreducible",
    "Specialize the type arguments before lowering this coercion"
  | Not_a_subtype ->
    "IL does not prove the requested source type to be a subtype of the target",
    "Preserve this SubE as Unsupported instead of inventing a coercion"
  | Unsupported_type_shape ->
    "this SubE shape is neither a representation identity nor a certified concrete VariantT injection",
    "Add tuple or iteration coercion only with an equivalent source-surface proof"
  | Incomplete_source_surface error ->
    describe_surface_error error,
    "Emit and register every exact source VariantT alternative before constructing this injection"
  | Missing_target_alternative ->
    "a certified source alternative has no emitted target representation",
    "Keep this SubE Unsupported until the target constructor is emitted"
  | Ambiguous_target_alternative ->
    "a certified source alternative has multiple target representations",
    "Disambiguate the target constructor surface before lowering this SubE"
  | Incompatible_payload ->
    "matching source and target alternatives have incompatible payload representations",
    "Keep this SubE Unsupported until payload carriers and witnesses agree"
  | Non_injective_target ->
    "two source alternatives map to the same target representation",
    "A source-exact partial projection requires a one-to-one target image"
