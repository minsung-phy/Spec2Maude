type output =
  { statements : Maude_ir.generated list
  ; diagnostics : Diagnostics.t list
  }

val empty : output
val append : output -> output -> output

val unsupported :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit ->
  Diagnostics.t

val skipped :
  ?suggestion:string ->
  ?source_echo:string ->
  ctx:Context.t ->
  origin:Origin.t ->
  constructor:string ->
  reason:string ->
  unit ->
  Diagnostics.t

val one_diagnostic : Diagnostics.t -> output
val has_fatal : Diagnostics.t list -> bool
val gen : Origin.t -> Maude_ir.statement_node -> Maude_ir.generated
val app : string -> Maude_ir.term list -> Maude_ir.term
val dedup_conditions : Maude_ir.eq_condition list -> Maude_ir.eq_condition list
val dedup_rule_conditions : Maude_ir.rule_condition list -> Maude_ir.rule_condition list
val dedup_generated : Maude_ir.generated list -> Maude_ir.generated list

val rule_origin : Origin.t -> int -> Il.Ast.rule -> Origin.t
val rule_label : Il.Ast.id -> Il.Ast.id -> int -> string

val validate_rule_marker :
  Context.t ->
  Origin.t ->
  expected_kind:Analysis.Relation_graph.relation_kind ->
  expected_mixop:Il.Ast.mixop ->
  Il.Ast.rule ->
  Diagnostics.t list

val validate_rule_premise_marker :
  Context.t ->
  Origin.t ->
  expected_kind:Analysis.Relation_graph.relation_kind ->
  expected_mixop:Il.Ast.mixop ->
  Il.Ast.prem ->
  Il.Ast.mixop ->
  Diagnostics.t list

val component_sort :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.typ ->
  Maude_ir.sort option * Diagnostics.t list

val component_sorts :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.typ list ->
  Maude_ir.sort list option * Diagnostics.t list

val tuple_carrier : Maude_ir.sort list -> Maude_ir.term list -> Maude_ir.term
val execution_output_sort : Maude_ir.sort list -> Maude_ir.sort
val relation_conf_sort : Il.Ast.id -> Maude_ir.sort
val frozen_all : int -> Maude_ir.attr list

val translate_rule_binds :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.quant list ->
  Expr_translate.env * Maude_ir.generated list * Diagnostics.t list

val add_introduced_bindings :
  Expr_translate.env ->
  (string * Expr_translate.binding) list ->
  Expr_translate.env

val add_safe_introduced_bindings :
  Expr_translate.env ->
  Maude_ir.term list ->
  Maude_ir.eq_condition list ->
  (string * Expr_translate.binding) list ->
  Expr_translate.env

val exp_components_match :
  Context.t ->
  Origin.t ->
  string ->
  Il.Ast.typ list ->
  Il.Ast.exp ->
  Il.Ast.exp list option * Diagnostics.t list

val lower_pattern_components :
  Context.t ->
  Expr_translate.env ->
  Origin.t ->
  Il.Ast.exp list ->
  Maude_ir.term list option
  * Maude_ir.eq_condition list
  * (string * Expr_translate.binding) list
  * Diagnostics.t list

val lower_value_components :
  Context.t ->
  Expr_translate.env ->
  Origin.t ->
  string ->
  Il.Ast.exp list ->
  Maude_ir.term list option * Maude_ir.eq_condition list * Diagnostics.t list

val relation_call : string -> Maude_ir.term list -> Maude_ir.term

val generated_statement_diagnostics :
  Context.t -> Maude_ir.generated -> Diagnostics.t list

val rule_hint_diagnostics :
  Context.t -> Origin.t -> string -> Il.Ast.id -> Diagnostics.t list
