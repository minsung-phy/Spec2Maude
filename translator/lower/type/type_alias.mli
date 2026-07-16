open Il.Ast
open Maude_ir

val translate_alias :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  Static_key.env ->
  string option ->
  string ->
  term ->
  typ ->
  Type_result.result

val translate_category_union :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  Static_key.env ->
  string option ->
  string ->
  term ->
  typ ->
  Type_result.result

val translate_subtype_membership :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  term ->
  typ ->
  Type_result.result
