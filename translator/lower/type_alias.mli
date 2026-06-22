open Il.Ast
open Maude_ir

val translate_alias :
  Type_support.static_env ->
  Context.t ->
  Origin.t ->
  string ->
  Static_key.env ->
  string option ->
  term ->
  typ ->
  Type_support.result

val translate_category_union :
  Type_support.static_env ->
  Context.t ->
  Origin.t ->
  string ->
  Static_key.env ->
  string option ->
  term ->
  typ ->
  Type_support.result
