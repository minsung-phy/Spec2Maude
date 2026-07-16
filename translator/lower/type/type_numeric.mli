val numeric_predicate_from_typcase :
  Il.Ast.param list ->
  Il.Ast.typ ->
  Il.Ast.prem list ->
  (Il.Ast.id * Il.Ast.typ * Maude_ir.sort * Il.Ast.exp) option

val numeric_literal_terms_from_typcase :
  Il.Ast.param list ->
  Il.Ast.typ ->
  Il.Ast.prem list ->
  [ `Literals of Maude_ir.sort * Maude_ir.term list | `Range ] option

val register_numeric_wrapper :
  Context.t ->
  ?mixop:Il.Ast.mixop ->
  Origin.t ->
  string option ->
  string ->
  Maude_ir.term ->
  Maude_ir.sort ->
  string * string list

val translate_numeric_literal_case :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  string option ->
  string ->
  Maude_ir.term ->
  Il.Ast.mixop ->
  Maude_ir.sort ->
  Maude_ir.term list ->
  Type_result.result

val translate_numeric_predicate_case :
  Type_static_env.static_env ->
  Context.t ->
  Origin.t ->
  string option ->
  string ->
  Maude_ir.term ->
  Il.Ast.mixop ->
  Il.Ast.id ->
  Il.Ast.typ ->
  Maude_ir.sort ->
  Il.Ast.exp ->
  Type_result.result

val unsupported_numeric_range :
  Context.t -> Origin.t -> Il.Ast.typcase -> Diagnostics.t
