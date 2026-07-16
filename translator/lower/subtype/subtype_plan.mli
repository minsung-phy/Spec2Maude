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

val canonical_typ :
  il_env:Il.Env.t ->
  static_typ_env:(string * Il.Ast.typ) list ->
  Il.Ast.typ ->
  (Il.Ast.typ, error) result

val make :
  il_env:Il.Env.t ->
  source_index:Analysis.Source_index.t ->
  constructors:Constructor_registry.t ->
  static_typ_env:(string * Il.Ast.typ) list ->
  Il.Ast.typ ->
  Il.Ast.typ ->
  (t, error) result

val describe_error : error -> string * string
