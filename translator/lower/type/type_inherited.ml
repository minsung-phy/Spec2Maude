open Il.Ast
open Util.Source

open Type_diagnostic

let pos_leq left right =
  left.file = right.file
  && (left.line < right.line
      || (left.line = right.line && left.column <= right.column))

let region_contains outer inner =
  outer.left.file = inner.left.file
  && outer.right.file = inner.right.file
  && pos_leq outer.left inner.left
  && pos_leq inner.right outer.right

let mixop_atom_regions mixop =
  Xl.Mixop.flatten mixop
  |> List.concat
  |> List.map (fun atom -> atom.at)

let atom_text_has_word_char text =
  let rec loop index =
    index < String.length text
    &&
    (match text.[index] with
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
    | _ -> loop (index + 1))
  in
  loop 0

let mixop_has_source_word mixop =
  Xl.Mixop.flatten mixop
  |> List.concat
  |> List.exists (fun atom -> atom_text_has_word_char (Xl.Atom.to_string atom))

let record_like_single_constructor_case ~case_count mixop components =
  case_count = 1
  && not (Type_shape.mixop_is_hole_only mixop)
  && List.length components > 1
  && not (mixop_has_source_word mixop)

let mixop_is_native_to_region mixop region =
  match mixop_atom_regions mixop with
  | [] -> false
  | atom_regions ->
    List.for_all (region_contains region) atom_regions

(* Elaboration expands syntax inclusion by copying the child's cases into the
   parent VariantT.  A copied case keeps the source regions of its constructor
   tokens; native cases lie inside the current VariantT declaration. *)
let typcase_is_inherited_from_other_region target_region
    (mixop, (_typ, _quants, _prems), _hints) =
  match mixop_atom_regions mixop with
  | [] -> false
  | _ -> not (mixop_is_native_to_region mixop target_region)

type typcase_signature =
  { signature_mixop : mixop
  ; signature_arity : int
  ; signature_atom_regions : region list
  }

let signature_of_typcase (mixop, (typ, _quants, _prems), _hints) =
  { signature_mixop = mixop
  ; signature_arity = List.length (Type_shape.typ_components typ)
  ; signature_atom_regions = mixop_atom_regions mixop
  }

let same_typcase_signature left right =
  Xl.Mixop.eq left.signature_mixop right.signature_mixop
  && left.signature_arity = right.signature_arity
  && left.signature_atom_regions = right.signature_atom_regions

let native_variant_case_signatures ctx target_id =
  Analysis.Source_index.entries (Context.source_index ctx)
  |> List.filter_map (fun (entry : Analysis.Source_index.entry) ->
    match entry.def.it with
    | TypD (child_id, params, insts)
      when child_id.it <> target_id.it && params = [] ->
      let signatures =
        insts
        |> List.filter_map (fun inst ->
          match inst.it with
          | InstD (_binds, args, deftyp) when args = [] ->
            (match deftyp.it with
            | VariantT cases ->
              cases
              |> List.filter (fun (mixop, (typ, _quants, _prems), _hints) ->
                mixop_is_native_to_region mixop typ.at)
              |> List.map signature_of_typcase
              |> Option.some
            | AliasT _ | StructT _ -> None)
          | InstD _ -> None)
        |> List.concat
      in
      if signatures = [] then None else Some (child_id, signatures)
    | _ -> None)

let category_typ id =
  VarT (id, []) $ id.at

let category_is_subtype ctx child_id parent_id =
  try
    Il.Eval.sub_typ
      (Context.il_env ctx)
      (category_typ child_id)
      (category_typ parent_id)
  with
  | Il.Eval.Irred -> false

let find_native_child_categories ctx target_id signature =
  native_variant_case_signatures ctx target_id
  |> List.filter_map (fun (child_id, signatures) ->
    if category_is_subtype ctx child_id target_id
       && List.exists (same_typcase_signature signature) signatures
    then
      Some (child_id, signatures)
    else
      None)

type inherited_category_case =
  { inherited_index : int
  ; inherited_child_id : id
  ; inherited_child_signatures : typcase_signature list
  ; inherited_signature : typcase_signature
  ; inherited_typcase : typcase
  }

let inherited_category_cases ctx target_id target_region cases =
  cases
  |> List.mapi (fun index typcase ->
    if typcase_is_inherited_from_other_region target_region typcase then
      let signature = signature_of_typcase typcase in
      find_native_child_categories ctx target_id signature
      |> List.map (fun (child_id, child_signatures) ->
        { inherited_index = index
        ; inherited_child_id = child_id
        ; inherited_child_signatures = child_signatures
        ; inherited_signature = signature
        ; inherited_typcase = typcase
        })
    else
      [])
  |> List.concat

let group_inherited_category_cases inherited =
  inherited
  |> List.fold_left
       (fun groups item ->
         match
           List.partition
             (function
               | first :: _ ->
                 first.inherited_child_id.it = item.inherited_child_id.it
               | [] -> false)
             groups
         with
         | [], rest -> [ item ] :: rest
         | group :: same, rest -> (group @ [ item ]) :: (same @ rest))
       []
  |> List.rev

let inherited_group_is_complete group =
  match group with
  | [] -> false
  | first :: _ ->
    let target_signatures =
      group |> List.map (fun item -> item.inherited_signature)
    in
    first.inherited_child_signatures
    |> List.for_all (fun child_signature ->
      List.exists (same_typcase_signature child_signature) target_signatures)

let inherited_group_child = function
  | [] -> None
  | first :: _ -> Some first.inherited_child_id

let category_is_strict_subtype ctx left right =
  category_is_subtype ctx left right
  && not (category_is_subtype ctx right left)

(* If copied cases describe both A and a larger child B with A <: B, the
   source inclusion is B, not two overlapping inclusions. *)
let maximal_inherited_groups ctx groups =
  groups
  |> List.filter (fun group ->
    match inherited_group_child group with
    | None -> false
    | Some child ->
      not
        (List.exists
           (fun other ->
             match inherited_group_child other with
             | Some other_child ->
               child.it <> other_child.it
               && category_is_strict_subtype ctx child other_child
             | None -> false)
           groups))

let inherited_group_indices group =
  group
  |> List.map (fun item -> item.inherited_index)
  |> List.sort_uniq Int.compare

let incomplete_group_is_covered complete_groups group =
  let covered =
    complete_groups
    |> List.concat_map inherited_group_indices
    |> List.sort_uniq Int.compare
  in
  inherited_group_indices group
  |> List.for_all (fun index -> List.mem index covered)

let inherited_skip_indices complete_groups =
  complete_groups
  |> List.map (List.map (fun item -> item.inherited_index))
  |> List.concat

let unsupported_incomplete_inherited_group ctx parent_origin target_id group =
  match group with
  | [] -> []
  | first :: _ ->
    let target_signatures =
      group |> List.map (fun item -> item.inherited_signature)
    in
    let missing =
      first.inherited_child_signatures
      |> List.filter (fun child_signature ->
        not (List.exists (same_typcase_signature child_signature) target_signatures))
      |> List.length
    in
    [ unsupported
        ~ctx
        ~origin:parent_origin
        ~constructor:"VariantT/category-union/recover-expanded"
        ~reason:
          (Printf.sprintf
             "expanded inherited cases for `%s` look like a partial copy of child category `%s`; emitting a full category-union equation would accept %d missing child case(s), but emitting target constructors would break isomorphism"
             target_id.it
             first.inherited_child_id.it
             missing)
        ~suggestion:
          "Recover the original source union alternative before lowering this partial inherited case group"
        ()
    ]

let concrete_variant_id (entry : Analysis.Source_index.entry) =
  match entry.def.it with
  | TypD (id, [], [ { it = InstD ([], [], { it = VariantT _; _ }); _ } ]) ->
    Some id
  | _ -> None

(* Constructor names remain owned by their declaring categories.  This graph
   records only the membership theorem proved by [Il.Eval.sub_typ]. *)
let subtype_category_children ctx target_id =
  let candidates =
    Analysis.Source_index.entries (Context.source_index ctx)
    |> List.filter_map concrete_variant_id
    |> List.filter (fun child ->
      child.it <> target_id.it
      && category_is_strict_subtype ctx child target_id)
  in
  candidates
  |> List.filter (fun child ->
    not
      (List.exists
         (fun other ->
           child.it <> other.it
           && category_is_strict_subtype ctx child other)
         candidates))
