type typcase_signature =
  { signature_mixop : Il.Ast.mixop
  ; signature_arity : int
  ; signature_atom_regions : Util.Source.region list
  }

type inherited_category_case =
  { inherited_index : int
  ; inherited_child_id : Il.Ast.id
  ; inherited_child_signatures : typcase_signature list
  ; inherited_signature : typcase_signature
  ; inherited_typcase : Il.Ast.typcase
  }

val record_like_single_constructor_case :
  case_count:int -> Il.Ast.mixop -> 'a list -> bool

val inherited_category_cases :
  Context.t ->
  Il.Ast.id ->
  Util.Source.region ->
  Il.Ast.typcase list ->
  inherited_category_case list

val group_inherited_category_cases :
  inherited_category_case list -> inherited_category_case list list

val inherited_group_is_complete : inherited_category_case list -> bool
val inherited_group_child : inherited_category_case list -> Il.Ast.id option

val maximal_inherited_groups :
  Context.t ->
  inherited_category_case list list ->
  inherited_category_case list list

val incomplete_group_is_covered :
  inherited_category_case list list -> inherited_category_case list -> bool

val inherited_skip_indices : inherited_category_case list list -> int list

val unsupported_incomplete_inherited_group :
  Context.t ->
  Origin.t ->
  Il.Ast.id ->
  inherited_category_case list ->
  Diagnostics.t list

val subtype_category_children :
  Context.t -> Il.Ast.id -> Il.Ast.id list
